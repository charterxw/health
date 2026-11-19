from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from datetime import datetime, timezone
import os
from .openai_service import (
    AIServiceError,
    generate_morning_insight,
    generate_evening_insight,
    is_ai_configured,
)
from .observations import EVENING_TITLE, LOCK, MORNING_TITLE, generate_weekly_observation
from .web_push import deliver_observations


def _safe_generate(func):
    if not is_ai_configured():
        return None
    try:
        return func()
    except AIServiceError as exc:
        print(f"AI analysis skipped: {exc}")
    except Exception as exc:
        print(f"AI analysis error: {type(exc).__name__}: {exc!r}")
    return None


def _has_insight(date, slot, title) -> bool:
    from .database import get_db

    with get_db() as conn:
        return conn.execute(
            """SELECT 1 FROM ai_insights
               WHERE date = ? AND time_slot = ? AND title = ?
                 AND provider IN ('openai', 'chatgpt_plan') LIMIT 1""",
            (date, slot, title),
        ).fetchone() is not None


def run_morning_pipeline():
    """Retry after wake-up until synced sleep data produces today's report."""
    if _has_insight(datetime.now().date().isoformat(), "morning", MORNING_TITLE):
        return None
    return _safe_generate(generate_morning_insight)


def run_evening_pipeline(now=None):
    """Catch up after a failed attempt or a restart during the evening."""
    with LOCK:
        now = now or datetime.now(scheduler.timezone)
        if now.hour < 21 or _has_insight(now.date().isoformat(), "evening", EVENING_TITLE):
            return None
        return _safe_generate(generate_evening_insight)


scheduler = BackgroundScheduler(timezone=os.getenv("TZ", "America/New_York"))


def start_scheduler():
    common = {"replace_existing": True, "max_instances": 1, "coalesce": True, "misfire_grace_time": 300}
    scheduler.add_job(deliver_observations, "interval", seconds=30, id="observation_push", **common)

    # Check for main sleep after the usual wake time and retry while it syncs.
    scheduler.add_job(run_morning_pipeline, CronTrigger(hour=8, minute="30,45"), id="morning_insight_early", **common)
    scheduler.add_job(run_morning_pipeline, CronTrigger(hour="9-11", minute="*/15"), id="morning_insight_retry", **common)
    scheduler.add_job(run_morning_pipeline, CronTrigger(hour=12, minute="0,15"), id="morning_insight_late_retry", **common)
    scheduler.add_job(run_evening_pipeline, CronTrigger(hour="21-23", minute="*/10", timezone=scheduler.timezone),
                      next_run_time=datetime.now(timezone.utc), id="evening_insight", **common)
    scheduler.add_job(lambda: _safe_generate(generate_weekly_observation), CronTrigger(day_of_week="mon", hour=9, minute=0), id="weekly_observation", **common)

    scheduler.start()

def stop_scheduler():
    if scheduler.running:
        scheduler.shutdown(wait=False)
