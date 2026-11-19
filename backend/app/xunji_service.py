"""Read the local archive of previously imported 训记 workouts."""
from __future__ import annotations

from contextlib import closing
from datetime import datetime, timedelta
import json
import os
from pathlib import Path
import sqlite3

DB_PATH = os.environ.get("XUNJI_DB_PATH", "/data/xunji_data.db") if os.path.exists("/data") else os.path.join(os.path.dirname(__file__), "..", "..", "data", "xunji_data.db")


def get_all_cached_workouts(days: int | None = 30, *, datestr: str | None = None) -> list:
    """Read existing workouts without creating or refreshing the archive."""
    path = Path(DB_PATH).resolve()
    if not path.is_file():
        return []
    query = "SELECT datestr, full_json FROM daily_trains WHERE length(full_json) > 2"
    params = ()
    if datestr is not None:
        query += " AND datestr = ?"
        params = (datestr,)
    elif days is not None:
        query += " AND datestr >= ?"
        params = ((datetime.now().date() - timedelta(days=max(0, days - 1))).isoformat(),)
    try:
        with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as conn:
            rows = conn.execute(query + " ORDER BY datestr DESC", params).fetchall()
    except sqlite3.Error as error:
        print(f"Xunji archive read error: {error}")
        return []
    results = []
    for date, raw in rows:
        try:
            trains = json.loads(raw)
        except (TypeError, ValueError):
            continue
        if isinstance(trains, list):
            results.extend(_format_train(date, train) for train in trains if isinstance(train, dict))
    return results


def _format_train(datestr: str, train: dict) -> dict:
    """Format a Xunji training record for frontend display."""
    movements = []
    for m in train.get("movements", []):
        sets = []
        for s in m.get("sets", []):
            if not s.get("done", True):
                continue
            sets.append({
                "done": s.get("done", True),
                "selfWeight": s.get("selfWeight"),
                "warmup": s.get("warmup"),
                "weight": s.get("weight", ""),
                "unit": s.get("unit", "kg"),
                "reps": s.get("reps", ""),
                "rpe": s.get("rpe", ""),
            })
        if sets:
            movements.append({"name": m.get("name", ""), "exetype": m.get("exetype", ""), "sets": sets})

    start_ms = train.get("start", 0)
    end_ms = train.get("end", 0)
    duration_min = round((end_ms - start_ms) / 60000) if start_ms and end_ms else 0

    return {
        "datestr": datestr,
        "title": train.get("title", ""),
        "localid": train.get("localid"),
        "source": "archive",
        "duration_minutes": duration_min,
        "movements": movements,
    }
