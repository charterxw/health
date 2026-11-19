"""Read all saved sets for one exact exercise, plus its frozen import archive."""
from __future__ import annotations

import hashlib
import json
import math
import unicodedata
from datetime import date

from .database import get_db
from . import xunji_service


def key(value):
    return "".join(unicodedata.normalize("NFKC", str(value or "")).casefold().split())


def number(value):
    if value is None or isinstance(value, bool) or value == "":
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def history(exercise_id):
    from .strength_training import catalog

    exercises = catalog()["exercises"]
    exercise = next((entry for entry in exercises if entry["id"] == exercise_id), None)
    if exercise is None:
        return None
    names = {}
    for entry in exercises:
        for name in [entry["name"], entry.get("english_name"), *entry.get("aliases", [])]:
            if name:
                names.setdefault(key(name), set()).add(entry["id"])
    records = []
    with get_db() as conn:
        rows = conn.execute("SELECT document_json FROM strength_sessions WHERE status='completed' ORDER BY started_at DESC").fetchall()
    for row in rows:
        session = json.loads(row[0])
        movements = [m for m in session["exercises"] if m["exercise_id"] == exercise_id]
        if movements:
            records.append({"source": "local", "session": {**session, "exercises": movements}})
    seen = set()
    for workout in xunji_service.get_all_cached_workouts(days=None):
        day = workout.get("datestr", "")
        try:
            if date.fromisoformat(day) > date.today():
                continue
        except (TypeError, ValueError):
            continue
        movements = []
        for index, movement in enumerate(workout.get("movements", [])):
            if names.get(key(movement.get("name"))) != {exercise_id}:
                continue
            default_mode = {"help": "assistance", "self": "bodyweight", "bodyweight": "bodyweight"}.get(movement.get("exetype"), exercise["load_mode"])
            units = {}
            for si, item in enumerate(movement.get("sets", [])):
                mode = "bodyweight" if item.get("selfWeight") else default_mode
                reps, weight = number(item.get("reps")), number(item.get("weight"))
                unit = {"lbs": "lb", "磅": "lb", "公斤": "kg", "千克": "kg"}.get(item.get("unit"), item.get("unit"))
                if not item.get("done", True) or reps is None or reps <= 0:
                    continue
                if mode != "bodyweight" and (unit not in {"kg", "lb"} or weight is None or weight < 0):
                    continue
                unit = unit if unit in {"kg", "lb"} else "kg"
                units.setdefault((unit, mode), []).append({"id": f"{index}-{si}", "reps": reps,
                    "weight": None if mode == "bodyweight" else weight, "warmup": item.get("warmup") is True, "completed_at": day})
            for (unit, mode), sets in units.items():
                movements.append({"id": f"archive-{index}-{unit}-{mode}", "exercise_id": exercise_id,
                    "name": exercise["name"], "unit": unit, "load_mode": mode, "sets": sets})
        if not movements:
            continue
        identity = str(workout.get("localid") or hashlib.sha256(json.dumps(workout, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:24])
        identity = f"archive:{day}:{identity}"
        if identity in seen:
            continue
        seen.add(identity)
        records.append({"source": "archive", "session": {"id": identity, "title": workout.get("title") or "训记档案",
            "status": "completed", "started_at": day, "ended_at": None, "exercises": movements}})
    records.sort(key=lambda row: row["session"]["started_at"], reverse=True)
    return {"exercise_id": exercise_id, "records": records, "coverage": "all_saved_and_cached_archive"}
