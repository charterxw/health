import logging

from fastapi import APIRouter, HTTPException, Query
from ..database import get_db
from ..observations import EVENING_TITLE, MORNING_TITLE, serialize, generate_weekly_observation
from ..openai_service import (
    AIServiceError,
    generate_morning_insight,
    generate_evening_insight,
)

router = APIRouter(prefix="/api/insights", tags=["insights"])
logger = logging.getLogger(__name__)


def _generate(func):
    try:
        return func()
    except AIServiceError as exc:
        raise HTTPException(
            status_code=exc.status_code,
            detail={"message": str(exc), "code": exc.code},
        ) from exc
    except Exception as exc:
        logger.exception("Unexpected analysis failure")
        raise HTTPException(
            status_code=503,
            detail="Analysis is temporarily unavailable",
        ) from exc


@router.get("/today")
def get_today_insights():
    from datetime import datetime

    today = datetime.now().strftime("%Y-%m-%d")
    with get_db() as conn:
        rows = conn.execute(
            """SELECT * FROM ai_insights WHERE date = ? AND provider IN ('openai', 'chatgpt_plan')
               AND ((time_slot='morning' AND title=?) OR (time_slot='evening' AND title=?)
                    OR time_slot='sleep')
               ORDER BY (time_slot='sleep'), id DESC""",
            (today, MORNING_TITLE, EVENING_TITLE),
        ).fetchall()
    results = {}
    for row in rows:
        slot = "morning" if row["time_slot"] == "sleep" else row["time_slot"]
        if slot not in results:
            results[slot] = dict(serialize(row), time_slot=slot)
    return [results[slot] for slot in ("morning", "evening") if slot in results]


@router.get("/history")
def get_insights_history(days: int = Query(7, ge=1, le=90)):
    with get_db() as conn:
        rows = conn.execute(
            """SELECT * FROM ai_insights
               WHERE provider IN ('openai', 'chatgpt_plan') ORDER BY date DESC,
               CASE time_slot WHEN 'morning' THEN 1 WHEN 'noon' THEN 2 WHEN 'evening' THEN 3 END
               LIMIT ?""",
            (days * 3,),
        ).fetchall()
        return [serialize(r) for r in rows]


@router.post("/generate/morning")
def trigger_morning():
    return _generate(generate_morning_insight)


@router.post("/generate/evening")
def trigger_evening():
    return _generate(generate_evening_insight)


@router.get("/training")
def get_training_analysis(history: bool = False):
    with get_db() as conn:
        if history:
            rows = conn.execute("SELECT * FROM training_analysis ORDER BY date DESC, id DESC").fetchall()
            return [serialize(row) for row in rows]
        row = conn.execute(
            """SELECT * FROM training_analysis
               WHERE provider IN ('openai', 'chatgpt_plan')
               ORDER BY date DESC, id DESC LIMIT 1"""
        ).fetchone()
        if row:
            return serialize(row)
        return {"available": False}


@router.post("/training/generate")
def trigger_training_analysis():
    analysis = _generate(generate_evening_insight)
    return dict(analysis, summary=analysis["content"])


@router.get("/sleep")
def get_sleep_insight():
    from datetime import datetime
    today = datetime.now().strftime("%Y-%m-%d")
    with get_db() as conn:
        row = conn.execute(
            """SELECT * FROM ai_insights WHERE date = ?
                 AND ((time_slot='morning' AND title=?) OR time_slot='sleep')
                 AND provider IN ('openai', 'chatgpt_plan')
               ORDER BY (title=?) DESC, id DESC LIMIT 1""",
            (today, MORNING_TITLE, MORNING_TITLE),
        ).fetchone()
        if row:
            return serialize(row)
    return {"available": False}


@router.post("/sleep/generate")
def trigger_sleep_analysis():
    return _generate(generate_morning_insight)


@router.get("/weekly")
def get_weekly_observation():
    with get_db() as conn:
        row = conn.execute("SELECT * FROM ai_insights WHERE time_slot='weekly' "
                           "AND provider IN ('openai', 'chatgpt_plan') ORDER BY date DESC, id DESC LIMIT 1").fetchone()
    return serialize(row) if row else {"available": False}


@router.post("/weekly/generate")
def trigger_weekly_observation():
    return _generate(generate_weekly_observation)


@router.get("/archive")
def get_observation_archive():
    with get_db() as conn:
        observations = [serialize(row) for row in conn.execute(
            """SELECT * FROM ai_insights WHERE time_slot IN ('sleep','morning','noon','evening','weekly')
               ORDER BY date DESC, id DESC"""
        )]
        training = [dict(serialize(row), time_slot="training", content=row["summary"])
                    for row in conn.execute("SELECT * FROM training_analysis ORDER BY date DESC, id DESC")]
    return sorted([*observations, *training], key=lambda report: report["date"], reverse=True)
