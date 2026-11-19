"""Explicit workout timestamps joined to later-synced physiological samples."""

import hashlib
import json
import math
import statistics
from datetime import datetime, timedelta, timezone
from uuid import UUID

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator

from .database import get_db


def iso(value):
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def instant(value):
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Timezone is required")
    return parsed.astimezone(timezone.utc)


class RecordedSet(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: UUID
    exercise: str = Field(min_length=1, max_length=120)
    started_at: AwareDatetime
    ended_at: AwareDatetime | None = None
    reps: int | None = Field(default=None, ge=1, le=1000)
    weight: float | None = Field(default=None, ge=0, le=2000, allow_inf_nan=False)
    unit: str = Field(default="kg", pattern="^(kg|lb)$")


class RecordedSession(BaseModel):
    model_config = ConfigDict(extra="forbid")
    id: UUID
    title: str = Field(default="力量训练", min_length=1, max_length=120)
    started_at: AwareDatetime
    ended_at: AwareDatetime | None = None
    timezone: str = Field(default="UTC", max_length=80)
    sets: list[RecordedSet] = Field(default_factory=list, max_length=500)
    heart_rate_source_id: str | None = Field(default=None, max_length=64)

    @model_validator(mode="after")
    def timeline(self):
        now = datetime.now(timezone.utc)
        if self.started_at > now + timedelta(minutes=5):
            raise ValueError("训练开始时间超过当前时间")
        if self.ended_at:
            if not self.started_at < self.ended_at <= now + timedelta(minutes=5):
                raise ValueError("训练起止时间无效")
            if self.ended_at - self.started_at > timedelta(hours=24):
                raise ValueError("单次训练不能超过24小时")
        previous_end = self.started_at
        ids = set()
        for index, item in enumerate(self.sets):
            if item.id in ids or item.started_at < previous_end:
                raise ValueError("组次不能重复或重叠")
            ids.add(item.id)
            if item.started_at > now + timedelta(minutes=5):
                raise ValueError("组次时间超过当前时间")
            if item.ended_at:
                if not item.started_at < item.ended_at <= now + timedelta(minutes=5):
                    raise ValueError("组次起止时间无效")
                previous_end = item.ended_at
            elif index != len(self.sets) - 1 or self.ended_at:
                raise ValueError("只有正在训练的最后一组可以未结束")
            if self.ended_at and (item.started_at >= self.ended_at or item.ended_at > self.ended_at):
                raise ValueError("组次必须在训练时间内")
        return self


class SaveSession(BaseModel):
    model_config = ConfigDict(extra="forbid")
    expected_version: int = Field(ge=0)
    session: RecordedSession


class VersionConflict(Exception):
    pass


def save_session(request: SaveSession):
    doc = request.session.model_dump(mode="json")
    # Normalize physical time regardless of the phone's UTC offset.
    doc["started_at"] = iso(request.session.started_at)
    doc["ended_at"] = iso(request.session.ended_at) if request.session.ended_at else None
    for record, item in zip(doc["sets"], request.session.sets):
        record["started_at"] = iso(item.started_at)
        record["ended_at"] = iso(item.ended_at) if item.ended_at else None
    encoded = json.dumps(doc, sort_keys=True, ensure_ascii=False)
    with get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT * FROM recorded_sessions WHERE id = ?", (doc["id"],)).fetchone()
        current = row["version"] if row else 0
        # A lost acknowledgement may safely retry the identical document.
        if row and row["document_json"] == encoded:
            return {"session": doc, "version": current}
        if current != request.expected_version:
            raise VersionConflict("另一页面已更新此记录；本机副本仍保留，请重新载入服务器记录")
        old = json.loads(row["document_json"]) if row else {}
        same_window = old.get("started_at") == doc["started_at"] and old.get("ended_at") == doc["ended_at"]
        conn.execute(
            """INSERT INTO recorded_sessions
               (id, document_json, version, started_at, ended_at, heart_rate_json, heart_rate_synced_at)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET document_json=excluded.document_json,
               version=excluded.version, started_at=excluded.started_at, ended_at=excluded.ended_at,
               heart_rate_json=excluded.heart_rate_json, heart_rate_synced_at=excluded.heart_rate_synced_at""",
            (doc["id"], encoded, current + 1, doc["started_at"], doc["ended_at"],
             row["heart_rate_json"] if row and same_window else None,
             row["heart_rate_synced_at"] if row and same_window else None),
        )
        conn.commit()
    return {"session": doc, "version": current + 1}


def get_session(session_id):
    with get_db() as conn:
        row = conn.execute("SELECT * FROM recorded_sessions WHERE id = ?", (str(session_id),)).fetchone()
    if row is None:
        return None
    return {"session": json.loads(row["document_json"]), "version": row["version"],
            "heart_rate": json.loads(row["heart_rate_json"]) if row["heart_rate_json"] else None,
            "heart_rate_synced_at": row["heart_rate_synced_at"]}


def list_sessions():
    with get_db() as conn:
        rows = conn.execute("SELECT document_json, version FROM recorded_sessions ORDER BY started_at DESC LIMIT 100").fetchall()
    return [{"session": json.loads(r["document_json"]), "version": r["version"]} for r in rows]


def normalize_samples(raw, start, end):
    sources, values, conflicts = {}, {}, set()
    invalid = 0
    for point in raw:
        try:
            heart = point["heartRate"]
            at = instant(heart["sampleTime"]["physicalTime"])
            bpm = float(heart["beatsPerMinute"])
            if not math.isfinite(bpm) or not 1 <= bpm <= 300 or not start <= at < end:
                raise ValueError("Invalid sample")
            source = point.get("dataSource") or {}
            identity = json.dumps(source, sort_keys=True, separators=(",", ":"))
            source_id = hashlib.sha256(identity.encode()).hexdigest()[:20]
            device = source.get("device") or {}
            label = device.get("displayName") or source.get("platform") or "未标明来源"
            sources[source_id] = {"id": source_id, "label": label,
                                  "platform": source.get("platform"), "device": device}
            key = (source_id, iso(at))
            if key in values and values[key]["bpm"] != bpm:
                conflicts.add(key)
            values[key] = {"at": iso(at), "bpm": bpm, "source_id": source_id}
        except (KeyError, TypeError, ValueError, OverflowError):
            invalid += 1
    points = sorted((v for k, v in values.items() if k not in conflicts), key=lambda p: p["at"])
    for source in sources.values():
        source["count"] = sum(p["source_id"] == source["id"] for p in points)
    return {"points": points, "sources": list(sources.values()), "invalid_count": invalid,
            "conflicting_timestamps": len(conflicts)}


def sample_stats(points, start, end):
    selected = [p for p in points if start <= instant(p["at"]) < end]
    values = [p["bpm"] for p in selected]
    times = [instant(p["at"]) for p in selected]
    gaps = [(b - a).total_seconds() for a, b in zip(times, times[1:])]
    edges = [start, *times, end]
    return {"sample_count": len(values), "mean_bpm": round(statistics.mean(values), 1) if values else None,
            "min_bpm": min(values) if values else None, "max_bpm": max(values) if values else None,
            "median_interval_seconds": round(statistics.median(gaps), 2) if gaps else None,
            "largest_gap_seconds": round(max((b - a).total_seconds() for a, b in zip(edges, edges[1:])), 1),
            "first_sample_at": iso(times[0]) if times else None, "last_sample_at": iso(times[-1]) if times else None}


def make_report(record):
    doc = record["session"]
    if not doc["ended_at"]:
        return None
    start, end = instant(doc["started_at"]), instant(doc["ended_at"])
    cache = record["heart_rate"] or {"sources": [], "points": []}
    sources = cache["sources"]
    source_id = doc.get("heart_rate_source_id")
    if source_id is None and len(sources) == 1:
        source_id = sources[0]["id"]
    selected_source = next((s for s in sources if s["id"] == source_id), None)
    points = [p for p in cache["points"] if selected_source and p["source_id"] == source_id]
    groups = []
    for index, item in enumerate(doc["sets"]):
        a, b = instant(item["started_at"]), instant(item["ended_at"])
        next_start = instant(doc["sets"][index + 1]["started_at"]) if index + 1 < len(doc["sets"]) else end + timedelta(seconds=60)
        after_end = min(b + timedelta(seconds=60), next_start)
        groups.append({"id": item["id"], "stats": sample_stats(points, a, b),
                       "after_set": sample_stats(points, b, after_end) if b < after_end else None})
    summary = sample_stats(points, start, end)
    status = "needs_source" if len(sources) > 1 and selected_source is None else (
        "available" if summary["sample_count"] else "waiting")
    return {"status": status, "sources": sources, "selected_source": selected_source,
            "summary": summary, "sets": groups, "points": points,
            "synced_at": record["heart_rate_synced_at"],
            "invalid_count": cache.get("invalid_count", 0),
            "conflicting_timestamps": cache.get("conflicting_timestamps", 0),
            "note": "按原始测量时间关联；组次使用左闭右开区间。样本均值不代表连续监测均值；心率反应可能滞后于动作。"}


def cache_heart_rate(session_id, expected_window, data):
    with get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute("SELECT started_at, ended_at FROM recorded_sessions WHERE id = ?", (str(session_id),)).fetchone()
        if row is None or (row["started_at"], row["ended_at"]) != expected_window:
            raise VersionConflict("训练时间已更新，请重新读取心率")
        conn.execute("UPDATE recorded_sessions SET heart_rate_json = ?, heart_rate_synced_at = ? WHERE id = ?",
                     (json.dumps(data), iso(datetime.now(timezone.utc)), str(session_id)))
        conn.commit()
