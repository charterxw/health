import json
from pathlib import Path

from fastapi import APIRouter, Query

from ..database import get_db_path
from ..xunji_service import get_all_cached_workouts
from ..workout_data import get_training_workouts
from ..strength_training import get_strength_workouts

router = APIRouter(prefix="/api/workouts", tags=["workouts"])


@router.get("/training")
async def get_training_data(days: int = Query(30, ge=1, le=366)):
    """Get App training and previously imported records."""
    return get_training_workouts(days)


@router.get("/training/archive")
def get_training_archive(days: int | None = Query(None, ge=1, le=366)):
    return get_all_cached_workouts(days)


@router.get("/training/{datestr}")
async def get_training_for_date(datestr: str):
    """Read saved training records for a date."""
    return [*get_all_cached_workouts(datestr=datestr),
            *[w for w in get_strength_workouts(366) if w["datestr"] == datestr]]


@router.post("/training/sync")
async def sync_training():
    """Keep older clients compatible with the read-only archive."""
    return {"synced": 0}


@router.get("/exercises")
def get_exercises():
    """Read the Google Health snapshot taken when activity imports ended."""
    path = Path(get_db_path()).with_name("google_exercise_archive.json")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return []


@router.get("/archive")
def get_workout_archive():
    return {"exercises": get_exercises(), "training": get_all_cached_workouts(None)}


@router.get("/recent")
@router.get("/")
def get_recent_workouts(limit: int = Query(10, ge=1, le=100)):
    return get_training_workouts(366)[:limit]


@router.get("/stats")
def get_workout_stats():
    workouts = get_training_workouts(366)
    movement_counts = {}
    total_minutes = 0
    for workout in workouts:
        total_minutes += workout.get("duration_minutes", 0) or 0
        for movement in workout.get("movements", []):
            name = movement.get("name") or "Unknown"
            movement_counts[name] = movement_counts.get(name, 0) + 1
    return {
        "total_workouts": len(workouts),
        "total_minutes": total_minutes,
        "by_movement": [
            {"name": name, "count": count}
            for name, count in sorted(movement_counts.items(), key=lambda item: item[1], reverse=True)
        ],
    }
