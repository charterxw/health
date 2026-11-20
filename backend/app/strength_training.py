"""Strength templates and user-entered sets, independent of device workouts.

A check mark records a completion time. It does not claim to measure when a
set began, and is deliberately separate from the timed physiological recorder.
"""
from __future__ import annotations

import json
from pathlib import Path
from datetime import datetime, timedelta, timezone
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, model_validator

from .database import get_db


class Document(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Exercise(Document):
    id: str = Field(min_length=1, max_length=80, pattern=r"^[a-z0-9-]+$")
    name: str = Field(min_length=1, max_length=100)
    muscles: list[str] = Field(default_factory=list, max_length=8)
    equipment: str = Field(default="", max_length=40)
    load_mode: Literal["external", "assistance", "bodyweight"] = "external"
    tracking: Literal["reps", "duration"] = "reps"
    training_type: Literal["strength", "mobility"] = "strength"
    english_name: str = Field(default="", max_length=200)
    aliases: list[str] = Field(default_factory=list, max_length=20)
    primary_muscles: list[str] = Field(default_factory=list, max_length=18)
    secondary_muscles: list[str] = Field(default_factory=list, max_length=18)
    description: str = Field(default="", max_length=2000)
    instructions: list[str] = Field(default_factory=list, max_length=20)
    equipment_evidence: str = Field(default="", max_length=100)
    weight_note: str = Field(default="", max_length=200)


EXERCISES = [Exercise(**entry) for entry in json.loads(
    (Path(__file__).parent / "data" / "exercises.json").read_text(encoding="utf-8"))]
EXERCISES.extend(Exercise(**entry) for entry in json.loads(
    (Path(__file__).parent / "data" / "posture_exercises.json").read_text(encoding="utf-8")))
EXERCISE_METADATA = {entry.id: entry.model_dump(mode="json") for entry in EXERCISES}


class TemplateSetTarget(Document):
    weight: float | None = Field(default=None, ge=0, le=2000, allow_inf_nan=False)
    reps: int = Field(ge=1, le=1000)


class TemplateExercise(Document):
    exercise_id: str = Field(min_length=1, max_length=80)
    set_count: int = Field(ge=1, le=30)
    unit: Literal["kg", "lb"] = "lb"
    rest_seconds: int = Field(default=90, ge=0, le=600)
    target_reps: int | None = Field(default=None, ge=1, le=1000)
    target_seconds: int | None = Field(default=None, ge=1, le=3600)
    progression: Literal["off", "double"] = "off"
    rep_min: int = Field(default=8, ge=1, le=100)
    rep_max: int = Field(default=12, ge=1, le=100)
    increment: float | None = Field(default=None, gt=0, le=100, allow_inf_nan=False)
    warmup_count: int | None = Field(default=None, ge=0, le=10)
    set_targets: list[TemplateSetTarget] | None = Field(default=None, min_length=1, max_length=30)
    targets_updated_at: AwareDatetime | None = None

    @model_validator(mode="after")
    def valid_range(self):
        if self.target_seconds is not None and (self.target_reps is not None or self.progression != "off"):
            raise ValueError("计时动作不能同时设置次数或重量进阶")
        if self.rep_max < self.rep_min:
            raise ValueError("目标次数上限不能小于下限")
        if self.warmup_count is not None and self.warmup_count >= self.set_count:
            raise ValueError("模板至少需要保留一个工作组")
        if self.set_targets is not None:
            if self.target_seconds is not None:
                raise ValueError("计时动作不使用重量次数预设")
            if self.warmup_count is None or len(self.set_targets) != self.set_count:
                raise ValueError("逐组目标须与总组数和热身设置一致")
            if self.targets_updated_at is None:
                raise ValueError("逐组目标需要更新时间")
        return self


class Template(Document):
    id: str = Field(min_length=1, max_length=80, pattern=r"^[a-z0-9-]+$")
    name: str = Field(min_length=1, max_length=100)
    exercises: list[TemplateExercise] = Field(min_length=1, max_length=40)
    description: str = Field(default="", max_length=1000)
    notes: str = Field(default="", max_length=2000)
    duration_min: int | None = Field(default=None, ge=5, le=180)
    duration_max: int | None = Field(default=None, ge=5, le=180)
    rotation_order: int | None = Field(default=None, ge=0, le=20)

    @model_validator(mode="after")
    def valid_duration(self):
        if (self.duration_min is None) != (self.duration_max is None) or (
            self.duration_min is not None and self.duration_min > self.duration_max
        ):
            raise ValueError("训练时长范围无效")
        return self


TEMPLATES = [
    Template(id="back-rear-delts-biceps", name="背·三角肌后束·二头", exercises=[
        TemplateExercise(exercise_id=key, set_count=count) for key, count in [
            ("single-arm-pulldown", 3), ("wide-grip-pulldown", 4),
            ("cable-y-raise", 4), ("machine-preacher-curl", 1), ("face-pull", 3),
        ]
    ]),
    Template(id="chest-side-delts-triceps", name="胸·三角肌中束·三头", exercises=[
        TemplateExercise(exercise_id=key, set_count=count) for key, count in [
            ("barbell-bench-press", 4), ("incline-dumbbell-press", 4),
            ("assisted-dip", 2), ("reverse-preacher-curl", 4), ("cable-y-raise", 2),
        ]
    ]),
]
TEMPLATES.extend(Template(**entry) for entry in json.loads(
    (Path(__file__).parent / "data" / "programs.json").read_text(encoding="utf-8")))
TEMPLATES.extend(Template(**entry) for entry in json.loads(
    (Path(__file__).parent / "data" / "supplemental_programs.json").read_text(encoding="utf-8")))
TEMPLATES.extend(Template(**entry) for entry in json.loads(
    (Path(__file__).parent / "data" / "posture_programs.json").read_text(encoding="utf-8")))
# The 2026-11 plan: each training day has a company half, a home half, and
# company-only / home-only versions of the whole day.
TEMPLATES.extend(Template(**entry) for entry in json.loads(
    (Path(__file__).parent / "data" / "pine_program.json").read_text(encoding="utf-8")))


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def seed_catalog(conn):
    for exercise in EXERCISES:
        conn.execute("INSERT OR IGNORE INTO strength_exercises VALUES (?, ?)",
                     (exercise.id, encode(exercise.model_dump(mode="json"))))
    for template in TEMPLATES:
        conn.execute("INSERT OR IGNORE INTO strength_templates VALUES (?, ?, 1)",
                     (template.id, encode(template.model_dump(mode="json"))))


def catalog():
    with get_db() as conn:
        exercises = conn.execute("SELECT document_json FROM strength_exercises ORDER BY rowid").fetchall()
        templates = conn.execute("SELECT document_json, version FROM strength_templates ORDER BY rowid").fetchall()
    docs = [json.loads(r[0]) for r in exercises]
    # Add descriptions to legacy entries while preserving their IDs and stored names.
    return {"exercises": [{**EXERCISE_METADATA.get(doc["id"], {}), **doc} for doc in docs],
            "templates": [{"template": json.loads(r[0]), "version": r[1]} for r in templates]}


class Conflict(Exception):
    pass


class DeletedSession(Exception):
    def __init__(self, tombstone):
        super().__init__("这场训练已删除")
        self.tombstone = tombstone


def create_exercise(exercise):
    doc = exercise.model_dump(mode="json")
    with get_db() as conn:
        row = conn.execute("SELECT document_json FROM strength_exercises WHERE id=?", (exercise.id,)).fetchone()
        if row and row[0] != encode(doc):
            raise Conflict("这个动作编号已存在，请重新添加")
        conn.execute("INSERT OR IGNORE INTO strength_exercises VALUES (?, ?)", (exercise.id, encode(doc)))
        conn.commit()
    return doc


def _require_exercises(conn, ids):
    known = {r[0] for r in conn.execute("SELECT id FROM strength_exercises")}
    if set(ids) - known:
        raise ValueError("包含尚未保存到动作库的动作")


class SaveTemplate(Document):
    expected_version: int = Field(ge=0)
    template: Template


def save_template(request):
    doc = request.template.model_dump(mode="json")
    payload = encode(doc)
    with get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        _require_exercises(conn, (m.exercise_id for m in request.template.exercises))
        for plan in request.template.exercises:
            exercise = json.loads(conn.execute("SELECT document_json FROM strength_exercises WHERE id=?", (plan.exercise_id,)).fetchone()[0])
            if exercise.get("tracking") == "duration":
                if plan.target_reps is not None or plan.progression != "off":
                    raise ValueError("计时动作请设置秒数，不使用次数或重量进阶")
            elif plan.target_seconds is not None:
                raise ValueError("计次动作请设置次数")
        row = conn.execute("SELECT document_json, version FROM strength_templates WHERE id=?", (doc["id"],)).fetchone()
        current = row[1] if row else 0
        if row and row[0] == payload:
            return {"template": doc, "version": current}
        if current != request.expected_version:
            raise Conflict("模板已在另一页面更新，请重新打开后编辑")
        conn.execute("INSERT INTO strength_templates VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
                     "document_json=excluded.document_json, version=excluded.version", (doc["id"], payload, current + 1))
        conn.commit()
    return {"template": doc, "version": current + 1}


class StrengthSet(Document):
    id: UUID
    weight: float | None = Field(default=None, ge=0, le=2000, allow_inf_nan=False)
    reps: int | None = Field(default=None, ge=1, le=1000)
    duration_seconds: int | None = Field(default=None, ge=1, le=3600)
    completed_at: AwareDatetime | None = None
    warmup: bool = False
    hard_reps: int | None = Field(default=None, ge=0, le=1000, strict=True)


class Prescription(Document):
    policy: Literal["double"] = "double"
    rep_min: int = Field(ge=1, le=100)
    rep_max: int = Field(ge=1, le=100)
    increment: float = Field(gt=0, le=100, allow_inf_nan=False)
    work_sets: int = Field(ge=1, le=50)
    weight: float | None = Field(default=None, ge=0, le=2000, allow_inf_nan=False)
    reps: int = Field(ge=1, le=100)
    action: Literal["establish", "hold", "increase", "less_assistance", "reps", "limit"]
    reason: str = Field(min_length=1, max_length=1000)
    basis_date: str | None = Field(default=None, max_length=40)

    @model_validator(mode="after")
    def valid_range(self):
        if self.rep_max < self.rep_min or not self.rep_min <= self.reps <= self.rep_max:
            raise ValueError("进阶目标次数无效")
        return self


class SessionExercise(Document):
    id: UUID
    exercise_id: str = Field(min_length=1, max_length=80)
    name: str = Field(min_length=1, max_length=100)
    equipment: str = Field(default="", max_length=40)
    weight_note: str = Field(default="", max_length=200)
    load_mode: Literal["external", "assistance", "bodyweight"] = "external"
    tracking: Literal["reps", "duration"] = "reps"
    training_type: Literal["strength", "mobility"] = "strength"
    unit: Literal["kg", "lb"] = "lb"
    rest_seconds: int = Field(default=90, ge=0, le=600)
    effort: Literal["easy", "normal", "hard"] | None = None
    primary_muscles: list[str] | None = Field(default=None, max_length=18)
    secondary_muscles: list[str] | None = Field(default=None, max_length=18)
    prescription: Prescription | None = None
    baseline_at: AwareDatetime | None = None
    sets: list[StrengthSet] = Field(min_length=1, max_length=50)


class Session(Document):
    id: UUID
    template_id: str | None = Field(default=None, max_length=80)
    title: str = Field(min_length=1, max_length=100)
    started_at: AwareDatetime
    ended_at: AwareDatetime | None = None
    timezone: str = Field(default="America/New_York", max_length=80)
    status: Literal["active", "completed", "discarded"] = "active"
    paused_at: AwareDatetime | None = None
    paused_seconds: float = Field(default=0, ge=0, allow_inf_nan=False)
    rest_until: AwareDatetime | None = None
    rest_set_id: UUID | None = None
    notes: str = Field(default="", max_length=4000)
    template_notes: str = Field(default="", max_length=2000)
    duration_min: int | None = Field(default=None, ge=5, le=180)
    duration_max: int | None = Field(default=None, ge=5, le=180)
    exercises: list[SessionExercise] = Field(default_factory=list, max_length=40)

    @model_validator(mode="after")
    def valid_session(self):
        if (self.duration_min is None) != (self.duration_max is None) or (
            self.duration_min is not None and self.duration_min > self.duration_max
        ):
            raise ValueError("训练时长范围无效")
        now = datetime.now(timezone.utc)
        end = self.ended_at or now
        try:
            ZoneInfo(self.timezone)
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError("训练时区无效")
        if self.started_at > now + timedelta(minutes=5):
            raise ValueError("训练开始时间超过当前时间")
        if (self.status == "active") != (self.ended_at is None):
            raise ValueError("训练状态与结束时间不一致")
        if end < self.started_at or end > now + timedelta(minutes=5):
            raise ValueError("训练起止时间无效")
        if self.paused_at and (self.status != "active" or not self.started_at <= self.paused_at <= now + timedelta(minutes=5)):
            raise ValueError("暂停时间无效")
        if self.paused_seconds > (end - self.started_at).total_seconds() + 300:
            raise ValueError("累计暂停时间无效")
        exercise_ids, set_ids = set(), set()
        for movement in self.exercises:
            timed = movement.tracking == "duration"
            if timed and (movement.load_mode != "bodyweight" or movement.prescription is not None):
                raise ValueError("计时动作使用自重记录，不使用重量进阶")
            if movement.id in exercise_ids:
                raise ValueError("动作记录编号重复")
            exercise_ids.add(movement.id)
            for item in movement.sets:
                if timed and (item.reps is not None or item.weight is not None):
                    raise ValueError("计时动作只记录秒数")
                if not timed and item.duration_seconds is not None:
                    raise ValueError("计次动作不能记录秒数")
                if item.id in set_ids:
                    raise ValueError("组次编号重复")
                set_ids.add(item.id)
                if item.completed_at:
                    if not self.started_at <= item.completed_at <= end + timedelta(seconds=1):
                        raise ValueError("组次完成时间必须在训练时间内")
                    if timed and item.duration_seconds is None:
                        raise ValueError("完成一组前请填写秒数")
                    if not timed and (item.reps is None or (movement.load_mode != "bodyweight" and item.weight is None)):
                        raise ValueError("完成一组前请填写重量和次数")
        return self


class SaveSession(Document):
    expected_version: int = Field(ge=0)
    session: Session


def _record(row):
    return {"session": json.loads(row["document_json"]), "version": row["version"]}


def list_sessions(limit=100):
    with get_db() as conn:
        rows = conn.execute("SELECT * FROM strength_sessions WHERE status != 'discarded' "
                            "ORDER BY started_at DESC LIMIT ?", (limit,)).fetchall()
    return [_record(row) for row in rows]


def get_session(session_id):
    with get_db() as conn:
        row = conn.execute("SELECT * FROM strength_sessions WHERE id=?", (str(session_id),)).fetchone()
    return _record(row) if row else None


def list_session_deletions():
    with get_db() as conn:
        return [dict(row) for row in conn.execute("SELECT * FROM strength_session_deletions ORDER BY deleted_at")]


def delete_session(session_id, expected_version):
    """Delete a completed workout and prevent stale clients recreating its ID."""
    session_id = str(session_id)
    with get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        tombstone = conn.execute("SELECT * FROM strength_session_deletions WHERE id=?", (session_id,)).fetchone()
        if tombstone:
            return dict(tombstone)  # Safe if the first response was lost.
        row = conn.execute("SELECT * FROM strength_sessions WHERE id=?", (session_id,)).fetchone()
        if row is None:
            return None
        if row["version"] != expected_version:
            raise Conflict("这场训练已有更新，请刷新后再删除")
        if row["status"] != "completed":
            raise ValueError("只能从历史中删除已完成的训练")
        deleted = {"id": session_id, "version": row["version"] + 1,
                   "deleted_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")}
        conn.execute("INSERT INTO strength_session_deletions VALUES (?, ?, ?)", tuple(deleted.values()))
        conn.execute("DELETE FROM strength_physiology WHERE session_id=?", (session_id,))
        conn.execute("DELETE FROM strength_reviews WHERE session_id=? OR instr(input_json,?)>0", (session_id, session_id))
        conn.execute("DELETE FROM workout_push_deliveries WHERE session_id=?", (session_id,))
        conn.execute("DELETE FROM strength_sessions WHERE id=?", (session_id,))
        # Invalidate only saved analyses whose recorded evidence names this ID.
        for table in ("training_analysis", "ai_insights"):
            conn.execute(f"DELETE FROM {table} WHERE instr(input_json, ?)>0", (session_id,))
        conn.commit()
    return deleted


def save_session(request):
    doc = request.session.model_dump(mode="json")
    # Canonical UTC timestamps keep ordering and retries independent of offsets.
    def utc(value):
        return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z") if value else None
    for key in ("started_at", "ended_at", "paused_at", "rest_until"):
        doc[key] = utc(getattr(request.session, key))
    for movement, model in zip(doc["exercises"], request.session.exercises):
        for item, parsed in zip(movement["sets"], model.sets):
            item["completed_at"] = utc(parsed.completed_at)
    payload = encode(doc)
    with get_db() as conn:
        conn.execute("BEGIN IMMEDIATE")
        tombstone = conn.execute("SELECT * FROM strength_session_deletions WHERE id=?", (doc["id"],)).fetchone()
        if tombstone:
            raise DeletedSession(dict(tombstone))
        _require_exercises(conn, (m.exercise_id for m in request.session.exercises))
        row = conn.execute("SELECT * FROM strength_sessions WHERE id=?", (doc["id"],)).fetchone()
        current = row["version"] if row else 0
        if row and row["document_json"] == payload:
            conn.commit()
            return {"session": doc, "version": current}
        if current != request.expected_version:
            raise Conflict("服务器记录已有更新，本机记录已保留，请选择要继续使用的版本")
        if row and row["started_at"] != doc["started_at"]:
            raise ValueError("已保存训练的开始时间不能更改")
        if doc["status"] == "active":
            other = conn.execute("SELECT id FROM strength_sessions WHERE status='active' AND id != ?", (doc["id"],)).fetchone()
            if other:
                raise Conflict("服务器上已有另一场进行中的训练，请先完成它，再同步这场训练")
        conn.execute("INSERT INTO strength_sessions VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET "
                     "document_json=excluded.document_json, version=excluded.version, "
                     "ended_at=excluded.ended_at, status=excluded.status",
                     (doc["id"], payload, current + 1, doc["started_at"], doc["ended_at"], doc["status"]))
        conn.commit()
    return {"session": doc, "version": current + 1}


def get_strength_workouts(days=366):
    """Adapt completed sets for the existing history and comparison pipeline."""
    cutoff = (datetime.now().date() - timedelta(days=max(0, days - 1))).isoformat()
    # A local day can begin on the previous UTC date (e.g. UTC+14).
    utc_cutoff = (datetime.fromisoformat(cutoff) - timedelta(days=1)).date().isoformat()
    with get_db() as conn:
        rows = conn.execute("SELECT document_json FROM strength_sessions WHERE status='completed' "
                            "AND started_at >= ? ORDER BY started_at DESC", (utc_cutoff + "T00:00:00Z",)).fetchall()
    result = []
    for row in rows:
        doc = json.loads(row[0])
        started = datetime.fromisoformat(doc["started_at"].replace("Z", "+00:00"))
        ended = datetime.fromisoformat(doc["ended_at"].replace("Z", "+00:00"))
        local = started.astimezone(ZoneInfo(doc["timezone"]))
        if local.date().isoformat() < cutoff:
            continue
        movements = []
        for movement in doc["exercises"]:
            # Mobility records remain in session history, outside strength-volume analytics.
            if movement.get("training_type") == "mobility" or movement.get("tracking") == "duration":
                continue
            sets = [{"done": True, "weight": s["weight"] if s["weight"] is not None else 0,
                     "reps": s["reps"], "unit": movement["unit"], "warmup": s["warmup"],
                     "selfWeight": movement["load_mode"] == "bodyweight", "completed_at": s["completed_at"]}
                    for s in movement["sets"] if s["completed_at"]]
            if sets:
                movements.append({"name": movement["name"], "exercise_id": movement["exercise_id"],
                                  "exetype": {"assistance": "help", "bodyweight": "self"}.get(movement["load_mode"], "weight"),
                                  "sets": sets})
        if movements:
            result.append({"datestr": local.date().isoformat(), "time": local.strftime("%H:%M"),
                           "title": doc["title"], "localid": "strength:" + doc["id"], "source": "local",
                           "duration_minutes": round(max(0, (ended - started).total_seconds() - doc["paused_seconds"]) / 60),
                           "movements": movements})
    return result
