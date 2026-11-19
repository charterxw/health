"""Durable, late-arriving Google Health data for explicit strength windows.

Collection is independent of the phone's web page. Sensor values never enter
strength documents, so enrichment cannot conflict with a user's set edits.
"""

import asyncio
import json
import math
import statistics
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from zoneinfo import ZoneInfo

from . import google_health
from .database import get_db
from .recorded_sessions import instant, iso, normalize_samples, sample_stats

WEARABLES = "users/me/dataSourceFamilies/google-wearables"
MAX_WINDOW = timedelta(hours=24)
RETRY_HORIZON = timedelta(days=7)


def now_utc():
    return datetime.now(timezone.utc)


def ensure_job(conn, doc, now=None):
    """Called within the same transaction that saves the workout."""
    now = now or now_utc()
    if doc["status"] != "completed":
        conn.execute("DELETE FROM workout_push_deliveries WHERE session_id=? AND delivered_at IS NULL", (doc["id"],))
        conn.execute("UPDATE strength_physiology SET status='inactive', next_attempt_at=NULL, "
                     "lease_token=NULL, lease_until=NULL WHERE session_id=?", (doc["id"],))
        return
    start, end = instant(doc["started_at"]), instant(doc["ended_at"])
    valid = start < end and end - start <= MAX_WINDOW
    existing = conn.execute("SELECT * FROM strength_physiology WHERE session_id=?", (doc["id"],)).fetchone()
    if existing and (existing["started_at"], existing["ended_at"]) == (doc["started_at"], doc["ended_at"]):
        if existing["status"] == "inactive" and valid:
            conn.execute("UPDATE strength_physiology SET status='queued', next_attempt_at=? WHERE session_id=?",
                         (iso(max(now, end)), doc["id"]))
        return
    conn.execute("DELETE FROM workout_push_deliveries WHERE session_id=? AND delivered_at IS NULL", (doc["id"],))
    conn.execute(
        """INSERT INTO strength_physiology
           (session_id, started_at, ended_at, status, next_attempt_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(session_id) DO UPDATE SET started_at=excluded.started_at,
           ended_at=excluded.ended_at, status=excluded.status, next_attempt_at=excluded.next_attempt_at,
           payload_json=NULL, attempts=0, checked_at=NULL, lease_token=NULL, lease_until=NULL, error_code=NULL""",
        (doc["id"], doc["started_at"], doc["ended_at"], "queued" if valid else "unsupported",
         iso(max(now, end)) if valid else None),
    )


def seed_recent_jobs(days=7):
    """Additive startup backfill; no workouts or existing cache are rewritten."""
    with get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        rows = conn.execute("SELECT document_json FROM strength_sessions WHERE status='completed' "
                            "AND ended_at>=? ORDER BY ended_at DESC LIMIT 200",
                            (iso(now_utc() - timedelta(days=days)),)).fetchall()
        for row in rows:
            ensure_job(conn, json.loads(row[0]))
        conn.commit()
    return len(rows)


def _load(session_id):
    with get_db() as conn:
        session = conn.execute("SELECT document_json FROM strength_sessions WHERE id=?", (str(session_id),)).fetchone()
        job = conn.execute("SELECT * FROM strength_physiology WHERE session_id=?", (str(session_id),)).fetchone()
    return (json.loads(session[0]) if session else None, dict(job) if job else None)


def _selected_heart(payload, source_id):
    heart = payload.get("heart_rate") or {"points": [], "sources": []}
    sources = heart["sources"]
    if len(sources) == 1:
        source_id = sources[0]["id"]
    selected = next((s for s in sources if s["id"] == source_id), None)
    points = sorted((p for p in heart["points"] if selected and p["source_id"] == selected["id"]),
                    key=lambda point: instant(point["at"]))
    return heart, selected, points


def _heart_summary(payload, source_id, start, end):
    heart, source, points = _selected_heart(payload, source_id)
    summary = sample_stats(points, start, end)
    buckets = {}
    for point in points:
        minute = int((instant(point["at"]) - start).total_seconds() // 60)
        buckets.setdefault(minute, []).append(point["bpm"])
    minutes = math.ceil((end - start).total_seconds() / 60)
    summary.update({"minutes_with_samples": len(buckets), "window_minutes": minutes,
                    "minute_coverage_percent": round(len(buckets) / minutes * 100) if minutes else 0})
    chart = []
    for minute in range(minutes):
        values = buckets.get(minute, [])
        chart.append({"at": iso(start + timedelta(minutes=minute)),
                      "mean_bpm": round(statistics.mean(values), 1) if values else None,
                      "min_bpm": min(values) if values else None, "max_bpm": max(values) if values else None})
    return heart, source, summary, chart


def _daily_context(doc):
    date = instant(doc["started_at"]).astimezone(ZoneInfo(doc["timezone"])).date().isoformat()
    with get_db() as conn:
        row = conn.execute("SELECT date, sleep_hours, hrv, resting_hr, created_at FROM health_metrics WHERE date=?",
                           (date,)).fetchone()
    if not row:
        return None
    result = {"date": date, "cached_at": row["created_at"]}
    for field in ("sleep_hours", "hrv", "resting_hr"):
        result[field] = row[field] if row[field] and row[field] > 0 else None
    return result if any(result[k] is not None for k in ("sleep_hours", "hrv", "resting_hr")) else None


def get_report(session_id):
    doc, job = _load(session_id)
    if doc is None:
        return None
    report = {"session_id": doc["id"], "started_at": doc["started_at"], "ended_at": doc["ended_at"],
              "status": "not_requested", "checked_at": None, "next_attempt_at": None,
              "attempts": 0, "heart_rate": None, "metrics": {}, "daily_context": _daily_context(doc),
              "errors": {}, "syncing": False}
    if doc["status"] != "completed":
        report["status"] = "not_completed"
        return report
    if not job:
        return report
    if job["status"] == "unsupported":
        report["status"] = "unsupported"
        return report
    start, end = instant(doc["started_at"]), instant(doc["ended_at"])
    payload = json.loads(job["payload_json"]) if job["payload_json"] else {}
    heart, source, summary, chart = _heart_summary(payload, job["preferred_source_id"], start, end)
    errors = payload.get("errors", {})
    if len(heart["sources"]) > 1 and source is None:
        status = "needs_source"
    elif summary["sample_count"]:
        status = "ready" if summary["minute_coverage_percent"] >= 90 and summary["largest_gap_seconds"] <= 90 else "partial"
    elif job["error_code"] in ("connection_required", "permission_required"):
        status = "connection_required"
    elif not job["attempts"]:
        status = "pending"
    elif job["error_code"]:
        status = "error"
    else:
        status = "waiting_sync" if job["next_attempt_at"] else "unavailable"
    report.update({"status": status, "checked_at": job["checked_at"], "next_attempt_at": job["next_attempt_at"],
                   "attempts": job["attempts"], "syncing": bool(job["status"] == "queued" or (job["lease_token"] and job["lease_until"] > iso(now_utc()))),
                   "metrics": payload.get("metrics", {}), "errors": errors,
                   "heart_rate": {"summary": summary, "sources": heart["sources"], "selected_source": source,
                                  "chart": chart, "latest_cloud_sample_at": source.get("latest_cloud_sample_at") if source else heart.get("latest_cloud_sample_at"),
                                  "fetched_at": heart.get("fetched_at"), "invalid_count": heart.get("invalid_count", 0),
                                  "conflicting_timestamps": heart.get("conflicting_timestamps", 0)}})
    return report


def request_refresh(session_id):
    now = now_utc()
    with get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT document_json FROM strength_sessions WHERE id=?", (str(session_id),)).fetchone()
        if not row:
            return None
        doc = json.loads(row[0])
        if doc["status"] != "completed":
            raise ValueError("训练结束后才能获取这段时间的数据")
        ensure_job(conn, doc, now)
        job = conn.execute("SELECT * FROM strength_physiology WHERE session_id=?", (str(session_id),)).fetchone()
        if job["status"] != "unsupported":
            # Repeated taps do not bypass an in-flight lease or a 30s cooldown.
            inflight = job["lease_token"] and job["lease_until"] > iso(now)
            if not inflight and (not job["checked_at"] or now - instant(job["checked_at"]) >= timedelta(seconds=30)):
                conn.execute("UPDATE strength_physiology SET next_attempt_at=?, status='queued' WHERE session_id=?",
                             (iso(max(now, instant(doc["ended_at"]))), doc["id"]))
        conn.commit()
    return get_report(session_id)


def select_source(session_id, source_id):
    doc, job = _load(session_id)
    if doc is None:
        return None
    payload = json.loads(job["payload_json"]) if job and job["payload_json"] else {}
    sources = (payload.get("heart_rate") or {}).get("sources", [])
    if source_id not in {s["id"] for s in sources}:
        raise ValueError("请选择这场训练实际返回的心率来源")
    with get_db() as conn:
        conn.execute("UPDATE strength_physiology SET preferred_source_id=? WHERE session_id=?",
                     (source_id, str(session_id)))
        conn.commit()
    return get_report(session_id)


def _claim_one(now):
    with get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            """SELECT p.*, s.document_json FROM strength_physiology p JOIN strength_sessions s ON s.id=p.session_id
               WHERE s.status='completed' AND s.started_at=p.started_at AND s.ended_at=p.ended_at
                 AND p.next_attempt_at<=? AND (p.lease_until IS NULL OR p.lease_until<=?)
               ORDER BY CASE WHEN p.attempts=0 THEN 0 ELSE 1 END,
                 CASE WHEN p.attempts=0 THEN p.ended_at END DESC,
                 p.next_attempt_at, p.ended_at DESC LIMIT 1""", (iso(now), iso(now)),
        ).fetchone()
        if row is None:
            return None
        token = str(uuid4())
        conn.execute("UPDATE strength_physiology SET lease_token=?, lease_until=?, status='fetching', "
                     "attempts=attempts+1, checked_at=? WHERE session_id=?",
                     (token, iso(now + timedelta(minutes=10)), iso(now), row["session_id"]))
        conn.commit()
    job = dict(row)
    job.update(lease_token=token, attempts=job["attempts"] + 1, checked_at=iso(now))
    return job


def _error_code(error):
    response = getattr(error, "response", None)
    status = getattr(response, "status_code", None)
    if status == 401 or str(error) in ("Not authenticated", "No refresh token available. Re-authenticate.") or (status == 400 and "oauth2.googleapis.com" in str(getattr(error, "request", ""))):
        return "connection_required"
    if status == 403:
        return "permission_required"
    if status == 429:
        return "rate_limited"
    return "temporarily_unavailable"


def _metric(rows, key, field, at):
    values = []
    for row in rows:
        obj = row.get(key, {})
        if field not in obj:
            continue
        try:
            value = float(obj[field])
            if math.isfinite(value) and value >= 0:
                values.append(value)
        except (TypeError, ValueError, OverflowError):
            continue
    return {"value": (round(sum(values), 2) if key != "steps" else round(sum(values))) if values else None,
            "fetched_at": at, "resolution_seconds": 60}


async def _collect(job):
    start, end = instant(job["started_at"]), instant(job["ended_at"])
    payload = json.loads(job["payload_json"]) if job["payload_json"] else {}
    payload.setdefault("metrics", {})
    errors = {}
    if not google_health.is_authenticated():
        payload["errors"] = {"heart_rate": "connection_required"}
        return payload, "connection_required"
    fetch_end = min(now_utc(), end + timedelta(minutes=5))
    results = await asyncio.gather(
        google_health.get_heart_rate_window(start, fetch_end, data_source_family=WEARABLES),
        google_health.get_activity_window("steps", start, end),
        google_health.get_activity_window("active-energy-burned", start, end),
        return_exceptions=True,
    )
    at = iso(now_utc())
    for name, result in zip(("heart_rate", "steps", "active_energy"), results):
        if isinstance(result, BaseException):
            errors[name] = _error_code(result)
            continue
        if name == "heart_rate":
            heart = normalize_samples(result, start, fetch_end)
            latest = max((instant(p["at"]) for p in heart["points"]), default=None)
            latest_by_source = {}
            for point in heart["points"]:
                stamp = instant(point["at"])
                latest_by_source[point["source_id"]] = max(stamp, latest_by_source.get(point["source_id"], stamp))
            heart["points"] = [p for p in heart["points"] if instant(p["at"]) < end]
            counts = {}
            for point in heart["points"]:
                counts[point["source_id"]] = counts.get(point["source_id"], 0) + 1
            heart["sources"] = [{**source, "count": counts[source["id"]],
                                 "latest_cloud_sample_at": iso(latest_by_source[source["id"]])}
                                for source in heart["sources"] if counts.get(source["id"])]
            heart.update(latest_cloud_sample_at=iso(latest) if latest else None, fetched_at=at)
            payload["heart_rate"] = heart
        elif name == "steps":
            payload["metrics"][name] = _metric(result, "steps", "countSum", at)
        else:
            payload["metrics"][name] = _metric(result, "activeEnergyBurned", "kcalSum", at)
    payload["errors"] = errors
    return payload, errors.get("heart_rate")


def _next_attempt(job, payload, error, now):
    end = instant(job["ended_at"])
    if now >= end + RETRY_HORIZON:
        return None
    if error in ("connection_required", "permission_required", "rate_limited") or "rate_limited" in payload.get("errors", {}).values():
        delay = timedelta(minutes=30)
    else:
        age = now - end
        delay = timedelta(seconds=60) if age < timedelta(minutes=15) else (
            timedelta(minutes=5) if age < timedelta(hours=2) else (
                timedelta(minutes=30) if age < timedelta(days=1) else (
                    timedelta(hours=2) if age < timedelta(days=3) else timedelta(hours=6))))
        # A well-covered window that has synced past its end needs only a later
        # correction check, while sparse/empty results continue ordinary retries.
        heart, source, stats, _ = _heart_summary(payload, job["preferred_source_id"], instant(job["started_at"]), end)
        complete = (not payload.get("errors") and source and stats["minute_coverage_percent"] >= 90 and stats["largest_gap_seconds"] <= 90
                    and source.get("latest_cloud_sample_at") and instant(source["latest_cloud_sample_at"]) >= end
                    and all(payload.get("metrics", {}).get(k, {}).get("value") is not None for k in ("steps", "active_energy")))
        if complete:
            if age >= timedelta(days=1):
                return None
            delay = timedelta(hours=6)
    return iso(min(now + delay, end + RETRY_HORIZON))


async def process_due_jobs(limit=3):
    processed = 0
    for _ in range(limit):
        job = _claim_one(now_utc())
        if not job:
            break
        try:
            payload, error = await _collect(job)
        except Exception as exc:
            payload = json.loads(job["payload_json"]) if job["payload_json"] else {}
            error = _error_code(exc)
            payload["errors"] = {**payload.get("errors", {}), "heart_rate": error}
        now = now_utc()
        next_at = _next_attempt(job, payload, error, now)
        status = "error" if error else ("ready" if (payload.get("heart_rate") or {}).get("points") else "waiting")
        with get_db() as conn:
            # A changed time window, discard or expired/reclaimed lease makes
            # an old in-flight response ineligible to write into the record.
            cursor = conn.execute(
                """UPDATE strength_physiology SET payload_json=?, status=?, error_code=?,
                   next_attempt_at=?, lease_token=NULL, lease_until=NULL
                   WHERE session_id=? AND lease_token=? AND started_at=? AND ended_at=?""",
                (json.dumps(payload, ensure_ascii=False), status, error, next_at, job["session_id"],
                 job["lease_token"], job["started_at"], job["ended_at"]),
            )
            conn.commit()
        processed += cursor.rowcount
    return processed


def run_collection():
    result = asyncio.run(process_due_jobs())
    from .web_push import deliver_ready
    deliver_ready()
    return result
