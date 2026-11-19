"""Shared view of imported history and workouts recorded in this dashboard."""
from . import xunji_service
from .strength_training import get_strength_workouts


def get_training_workouts(days=366):
    imported = xunji_service.get_all_cached_workouts(days)
    return sorted([*imported, *get_strength_workouts(days)],
                  key=lambda w: (w.get("datestr", ""), w.get("time", "")), reverse=True)
