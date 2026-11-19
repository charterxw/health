from datetime import datetime
from typing import Literal

from fastapi import APIRouter, HTTPException, Query
from ..database import (
    cache_health_metrics,
    get_cached_health_metrics,
    get_cached_health_today,
)
from ..google_health import get_today_metric, is_authenticated, get_today_metrics as gh_today, get_history_metrics as gh_history

router = APIRouter(prefix="/api/health", tags=["health"])

TodayMetric = Literal["steps", "distance_km", "calories_burned", "active_minutes", "sleep_hours", "hrv", "resting_hr"]


@router.get("/today")
async def get_today_metrics(metric: TodayMetric | None = None):
    if is_authenticated():
        today = datetime.now().date().isoformat()
        try:
            if metric is not None:
                # The history and full-summary reads own the complete daily cache.
                return {"date": today, **await get_today_metric(metric, today)}
            metrics = await gh_today()
            cache_health_metrics(metrics)
            return metrics
        except Exception as e:
            print(f"Google Health today error: {type(e).__name__}: {e!r}")
            cached = get_cached_health_today()
            if cached:
                if metric is not None:
                    return {"date": cached["date"], metric: cached[metric], "_stale": True}
                cached["_stale"] = True
                return cached
            raise HTTPException(status_code=502, detail="Google Health data is temporarily unavailable")
    raise HTTPException(status_code=409, detail="Google Health is not connected")


@router.get("/history")
async def get_health_history(days: int = Query(14, ge=1, le=366)):
    if is_authenticated():
        try:
            metrics = await gh_history(days)
            cache_health_metrics(metrics)
            return metrics
        except Exception as e:
            print(f"Google Health history error: {type(e).__name__}: {e!r}")
            cached = get_cached_health_metrics(days)
            if cached:
                for row in cached:
                    row["_stale"] = True
                return cached
            raise HTTPException(status_code=502, detail="Google Health history is temporarily unavailable")
    cached = get_cached_health_metrics(days)
    if cached:
        for row in cached:
            row["_stale"] = True
        return cached
    raise HTTPException(status_code=409, detail="Google Health is not connected")

@router.get("/sleep")
async def get_sleep_data(days: int = Query(14, ge=1, le=90)):
    from ..google_health import get_sleep_history
    if is_authenticated():
        try:
            return await get_sleep_history(days)
        except Exception as e:
            print(f"Google Health sleep error: {type(e).__name__}: {e!r}")
            raise HTTPException(status_code=502, detail="Google Health sleep data is temporarily unavailable")
    raise HTTPException(status_code=409, detail="Google Health is not connected")
