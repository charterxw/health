"""Google Health API v4 integration service."""

import os
import json
import asyncio
import math
import tempfile
import threading
import httpx
from datetime import datetime, timedelta
from urllib.parse import urlencode

HEALTH_API_BASE = "https://health.googleapis.com/v4"
TOKEN_URL = "https://oauth2.googleapis.com/token"
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"

SCOPES = " ".join([
    "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
    "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
    "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
])
DEVICE_SETTINGS_SCOPE = "https://www.googleapis.com/auth/googlehealth.settings.readonly"
HEALTH_SCOPES = frozenset(SCOPES.split()) | {DEVICE_SETTINGS_SCOPE}


def isolated_scopes(values=None):
    if isinstance(values, str):
        values = values.split()
    scopes = set(values or SCOPES.split()) & HEALTH_SCOPES
    return sorted(scopes or SCOPES.split())


def install_token(data, requested=None):
    granted = set(data.get('scope', '').split()) or set(isolated_scopes(requested))
    if not granted <= HEALTH_SCOPES:
        raise ValueError('Google Health credentials must contain only Health scopes')
    _tokens['access_token'] = data['access_token']
    if data.get('refresh_token'):
        _tokens['refresh_token'] = data['refresh_token']
    _tokens['expires_at'] = datetime.now().timestamp() + data.get('expires_in', 3600)
    _tokens['scopes'] = sorted(granted)
    _save_tokens()

# In-memory token storage (single user). For production, use encrypted DB/file.
_tokens: dict = {}
TOKEN_FILE = os.getenv("TOKEN_FILE", "tokens.json")
_refresh_lock = threading.Lock()


def _load_tokens():
    global _tokens
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE) as f:
            _tokens = json.load(f)


def _save_tokens():
    parent = os.path.dirname(TOKEN_FILE)
    if parent:
        os.makedirs(parent, exist_ok=True)
    # Background collectors and dashboard reads may overlap. Never expose a
    # partially-written token file to another reader.
    fd, temporary = tempfile.mkstemp(prefix=".health-token-", dir=parent or ".")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(_tokens, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, TOKEN_FILE)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def get_client_config():
    return {
        "client_id": os.getenv("GOOGLE_CLIENT_ID", ""),
        "client_secret": os.getenv("GOOGLE_CLIENT_SECRET", ""),
        "redirect_uri": os.getenv("GOOGLE_REDIRECT_URI", "http://localhost:8000/api/auth/callback"),
    }


def get_auth_url(state: str, device_sync: bool = False) -> str:
    cfg = get_client_config()
    _load_tokens()
    device_sync = device_sync or DEVICE_SETTINGS_SCOPE in _tokens.get('scopes', [])
    params = {
        "client_id": cfg["client_id"],
        "redirect_uri": cfg["redirect_uri"],
        "response_type": "code",
        "access_type": "offline",
        "include_granted_scopes": "false",
        "prompt": "consent",
        "scope": SCOPES + (" " + DEVICE_SETTINGS_SCOPE if device_sync else ""),
        "state": state,
    }
    return f"{AUTH_URL}?{urlencode(params)}"


async def exchange_code(code: str) -> dict:
    cfg = get_client_config()
    async with httpx.AsyncClient() as client:
        resp = await client.post(TOKEN_URL, data={
            "code": code,
            "client_id": cfg["client_id"],
            "client_secret": cfg["client_secret"],
            "redirect_uri": cfg["redirect_uri"],
            "grant_type": "authorization_code",
        })
        resp.raise_for_status()
        data = resp.json()
        install_token(data, SCOPES.split())
        return data


async def _refresh_access_token():
    cfg = get_client_config()
    if "refresh_token" not in _tokens:
        raise Exception("No refresh token available. Re-authenticate.")
    async with httpx.AsyncClient() as client:
        resp = await client.post(TOKEN_URL, data={
            "client_id": cfg["client_id"],
            "client_secret": cfg["client_secret"],
            "refresh_token": _tokens["refresh_token"],
            "grant_type": "refresh_token",
            "scope": " ".join(isolated_scopes(_tokens.get('scopes'))),
        })
        resp.raise_for_status()
        data = resp.json()
        install_token(data, _tokens.get('scopes'))


async def _get_token() -> str:
    _load_tokens()
    if not _tokens.get("access_token"):
        raise Exception("Not authenticated")
    if datetime.now().timestamp() >= _tokens.get("expires_at", 0) - 60:
        # The scheduler and FastAPI use different event loops. Waiting without
        # blocking either loop also lets cancellation safely abandon the wait.
        while not _refresh_lock.acquire(blocking=False):
            await asyncio.sleep(0.05)
        try:
            _load_tokens()
            if datetime.now().timestamp() >= _tokens.get("expires_at", 0) - 60:
                await _refresh_access_token()
        finally:
            _refresh_lock.release()
    return _tokens["access_token"]


def is_authenticated() -> bool:
    _load_tokens()
    return bool(_tokens.get("access_token"))


async def _api_get(url: str, params: dict | None = None, paginate: bool = False, collection: str = 'dataPoints') -> dict:
    token = await _get_token()
    all_points = []
    query = dict(params or {})
    if paginate:
        query.setdefault("pageSize", 1000)
    async with httpx.AsyncClient(timeout=30.0) as client:
        while True:
            resp = await client.get(url, params=query, headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
            })
            resp.raise_for_status()
            data = resp.json()
            all_points.extend(data.get(collection, []))
            if not paginate:
                break
            page_token = data.get("nextPageToken", "")
            if page_token:
                query["pageToken"] = page_token
            else:
                break
    return {collection: all_points}


async def _api_post(url: str, body: dict) -> dict:
    token = await _get_token()
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(url, json=body, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
        })
        resp.raise_for_status()
        return resp.json()


def _date_range(days: int):
    """Return (start, end) ISO date strings for the last N days."""
    end = datetime.now()
    start = end - timedelta(days=max(0, days - 1))
    return start.strftime("%Y-%m-%d"), end.strftime("%Y-%m-%d")


def _civil_date_body(start_date: str, end_date: str, window_days: int = 1) -> dict:
    """Build the request body for dailyRollUp using civil date format."""
    s = datetime.strptime(start_date, "%Y-%m-%d")
    e = datetime.strptime(end_date, "%Y-%m-%d")
    return {
        "range": {
            "start": {
                "date": {"year": s.year, "month": s.month, "day": s.day},
                "time": {"hours": 0, "minutes": 0, "seconds": 0, "nanos": 0},
            },
            "end": {
                "date": {"year": e.year, "month": e.month, "day": e.day},
                "time": {"hours": 23, "minutes": 59, "seconds": 59, "nanos": 0},
            },
        },
        "windowSizeDays": window_days,
    }


async def _daily_rollup(data_type: str, days: int) -> list:
    """Fetch dailyRollUp for interval-type data (steps, distance, calories)."""
    start_date, end_date = _date_range(days)
    url = f"{HEALTH_API_BASE}/users/me/dataTypes/{data_type}/dataPoints:dailyRollUp"
    body = _civil_date_body(start_date, end_date)
    data = await _api_post(url, body)
    return data.get("rollupDataPoints", [])


async def _list_data(data_type: str, days: int, filter_field: str = None) -> list:
    """Fetch a bounded, paginated set of data points."""
    url = f"{HEALTH_API_BASE}/users/me/dataTypes/{data_type}/dataPoints"
    start_date, end_date = _date_range(days)
    end_exclusive = (datetime.strptime(end_date, "%Y-%m-%d") + timedelta(days=1)).strftime("%Y-%m-%d")
    params = {}
    if filter_field:
        start_value, end_value = start_date, end_exclusive
        if filter_field.endswith("civil_end_time"):
            start_value += "T00:00:00"
            end_value += "T00:00:00"
        params["filter"] = f'{filter_field} >= "{start_value}" AND {filter_field} < "{end_value}"'
    if data_type in ("exercise", "sleep"):
        params["pageSize"] = 25
    else:
        params["pageSize"] = 10000
    data = await _api_get(url, params=params, paginate=True)
    return data.get("dataPoints", [])


async def _list_daily(data_type: str, days: int) -> list:
    """Fetch daily summary data within the requested local-date range."""
    snake = data_type.replace("-", "_")
    return await _list_data(data_type, days, f"{snake}.date")


async def _list_sleep(days: int) -> list:
    """Fetch sleep sessions by local wake date."""
    return await _list_data("sleep", days, "sleep.interval.civil_end_time")


async def _list_exercises(days: int = 120) -> list:
    """Fetch exercise/workout sessions by local start date."""
    return await _list_data("exercise", days, "exercise.interval.civil_start_time")


async def get_heart_rate_window(start: datetime, end: datetime, data_source_family: str | None = None) -> list:
    """Raw sample timestamps, not daily averages or synthetic time buckets."""
    from datetime import timezone
    if start.tzinfo is None or end.tzinfo is None or not start < end:
        raise ValueError("An aware, increasing time window is required")
    if (end - start).total_seconds() > 2 * 86400:
        raise ValueError("Heart-rate windows are limited to two days")
    iso = lambda value: value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    field = "heart_rate.sample_time.physical_time"
    params = {"pageSize": 10000, "filter": f'{field} >= "{iso(start)}" AND {field} < "{iso(end)}"'}
    if data_source_family:
        params["dataSourceFamily"] = data_source_family
    result = await _api_get(
        f"{HEALTH_API_BASE}/users/me/dataTypes/heart-rate/dataPoints",
        params=params,
        paginate=True,
    )
    return result.get("dataPoints", [])


async def get_activity_window(data_type: str, start: datetime, end: datetime) -> list:
    """One reconciled bucket over the exact physical workout window."""
    from datetime import timezone
    if data_type not in ("steps", "active-energy-burned"):
        raise ValueError("Unsupported workout metric")
    if start.tzinfo is None or end.tzinfo is None or not start < end or end - start > timedelta(days=2):
        raise ValueError("An aware window of at most two days is required")
    physical = lambda value: value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    result = await _api_post(
        f"{HEALTH_API_BASE}/users/me/dataTypes/{data_type}/dataPoints:rollUp",
        {"range": {"startTime": physical(start), "endTime": physical(end)},
         "windowSize": f"{max(60, math.ceil((end - start).total_seconds()))}s",
         "dataSourceFamily": "users/me/dataSourceFamilies/google-wearables"},
    )
    return result.get("rollupDataPoints", [])


def _exercise_minutes_by_date(points: list) -> dict:
    """Sum workout durations by local date (applying UTC offset). Only counts Fitbit data."""
    by_date = {}
    for pt in points:
        # Only count Fitbit-sourced exercises to avoid duplicates from HealthKit etc.
        src = pt.get("dataSource", {})
        if src.get("platform", "") not in ("FITBIT", ""):
            continue

        ex = pt.get("exercise", {})
        interval = ex.get("interval", {})
        civil = interval.get("civilEndTime", {})
        date_obj = civil.get("date", {})

        if date_obj:
            d = f"{date_obj.get('year')}-{date_obj.get('month', 0):02d}-{date_obj.get('day', 0):02d}"
        else:
            # No civil date — apply UTC offset to startTime
            st = interval.get("startTime", "")
            offset_str = interval.get("startUtcOffset", "0s")
            if st:
                try:
                    utc_dt = datetime.fromisoformat(st.replace("Z", "+00:00"))
                    offset_secs = int(offset_str.replace("s", ""))
                    local_dt = utc_dt + timedelta(seconds=offset_secs)
                    d = local_dt.strftime("%Y-%m-%d")
                except Exception:
                    d = st[:10]
            else:
                continue

        duration_str = ex.get("activeDuration", "0s")
        secs = float(duration_str.replace("s", "")) if duration_str.endswith("s") else 0
        mins = round(secs / 60)
        by_date[d] = by_date.get(d, 0) + mins
    return by_date


def _get_civil_date(pt: dict, type_key: str) -> str:
    """Extract civil date from a data point's interval."""
    obj = pt.get(type_key, pt)
    interval = obj.get("interval", {})
    civil = interval.get("civilStartTime", {})
    date_obj = civil.get("date", {})
    if date_obj:
        y = date_obj.get("year", 0)
        m = date_obj.get("month", 0)
        d = date_obj.get("day", 0)
        if y and m and d:
            return f"{y}-{m:02d}-{d:02d}"
    # Fallback to startTime
    return interval.get("startTime", "")[:10]


def _aggregate_by_date(points: list, type_key: str, value_key: str) -> dict:
    """Aggregate interval data points by civil date, summing values."""
    by_date = {}
    for pt in points:
        d = _get_civil_date(pt, type_key)
        if not d:
            continue
        obj = pt.get(type_key, {})
        val = obj.get(value_key, 0)
        if isinstance(val, str):
            val = int(val)
        by_date[d] = by_date.get(d, 0) + val
    return by_date


def _rollup_date(pt: dict) -> str:
    """Extract date string from a dailyRollUp data point."""
    date_obj = pt.get("civilStartTime", {}).get("date", {})
    if date_obj:
        y = date_obj.get("year", 0)
        m = date_obj.get("month", 0)
        d = date_obj.get("day", 0)
        if y and m and d:
            return f"{y}-{m:02d}-{d:02d}"
    return ""


def _extract_rollup(default_data, target_date, type_key, value_key, data=None):
    """Extract a value from dailyRollUp response for a specific date."""
    points = data if data is not None else default_data
    total = 0
    for pt in points:
        d = _rollup_date(pt)
        if d == target_date:
            obj = pt.get(type_key, pt)
            val = obj.get(value_key, obj.get("total", 0))
            if isinstance(val, str):
                val = float(val)
            total += val
    return total


def _rollup_by_date(points: list, type_key: str, value_key: str) -> dict:
    """Group dailyRollUp data points by date."""
    by_date = {}
    for pt in points:
        d = _rollup_date(pt)
        if not d:
            continue
        obj = pt.get(type_key, pt)
        val = obj.get(value_key, obj.get("total", 0))
        if isinstance(val, str):
            val = float(val)
        by_date[d] = by_date.get(d, 0) + val
    return by_date


def _extract_active_minutes(points: list, target_date: str = None) -> dict:
    """Extract active minutes from dailyRollUp, summing only moderate + vigorous."""
    by_date = {}
    for pt in points:
        d = _rollup_date(pt)
        if not d:
            continue
        am = pt.get("activeMinutes", {})
        levels = am.get("activeMinutesRollupByActivityLevel", [])
        total = 0
        for level in levels:
            activity = level.get("activityLevel", "")
            if activity in ("MODERATE", "VIGOROUS"):
                val = level.get("activeMinutesSum", 0)
                total += int(val) if isinstance(val, str) else val
        by_date[d] = by_date.get(d, 0) + total
    if target_date:
        return by_date.get(target_date, 0)
    return by_date


def _civil_date_from_time(value: dict) -> str:
    date_obj = value.get("date", {}) if value else {}
    if not date_obj:
        return ""
    year, month, day = date_obj.get("year"), date_obj.get("month"), date_obj.get("day")
    return f"{year}-{month:02d}-{day:02d}" if year and month and day else ""


def _sleep_date_and_hours(point: dict) -> tuple[str, float, bool]:
    """Return local wake date, asleep hours, and nap flag for a sleep session."""
    sleep = point.get("sleep", {})
    interval = sleep.get("interval", {})
    date = _civil_date_from_time(interval.get("civilEndTime", {}))
    end = interval.get("endTime", "")
    if not date and end:
        try:
            utc_dt = datetime.fromisoformat(end.replace("Z", "+00:00"))
            offset_secs = int(interval.get("endUtcOffset", "0s").replace("s", ""))
            date = (utc_dt + timedelta(seconds=offset_secs)).strftime("%Y-%m-%d")
        except Exception:
            date = end[:10]

    summary = sleep.get("summary", {})
    minutes_asleep = int(summary.get("minutesAsleep", 0) or 0)
    if minutes_asleep:
        hours = round(minutes_asleep / 60, 1)
    else:
        start = interval.get("startTime", "")
        try:
            st = datetime.fromisoformat(start.replace("Z", "+00:00"))
            et = datetime.fromisoformat(end.replace("Z", "+00:00"))
            hours = round((et - st).total_seconds() / 3600, 1)
        except Exception:
            hours = 0
    is_nap = bool(sleep.get("metadata", {}).get("nap", False))
    return date, hours, is_nap


def _sleep_quality(hours: float) -> str:
    if hours >= 8:
        return "Excellent"
    if hours >= 7:
        return "Good"
    if hours >= 6:
        return "Fair"
    return "Poor" if hours > 0 else "—"


def _daily_value_date(value: dict) -> str:
    date = value.get("date", {})
    year, month, day = date.get("year"), date.get("month"), date.get("day")
    return f"{year}-{month:02d}-{day:02d}" if year and month and day else ""


def _sleep_recovery_by_date(
    oxygen_points: list,
    respiratory_points: list,
    temperature_points: list,
    hrv_points: list | None = None,
    resting_hr_points: list | None = None,
) -> dict[str, dict]:
    """Normalize daily sleep-recovery records into one date-keyed payload."""
    result: dict[str, dict] = {}

    for point in oxygen_points:
        value = point.get("dailyOxygenSaturation", {})
        date = _daily_value_date(value)
        if date:
            result.setdefault(date, {}).update({
                "spo2_average": round(float(value.get("averagePercentage", 0)), 1),
                "spo2_lower_bound": round(float(value.get("lowerBoundPercentage", 0)), 1),
                "spo2_upper_bound": round(float(value.get("upperBoundPercentage", 0)), 1),
            })

    for point in respiratory_points:
        value = point.get("dailyRespiratoryRate", {})
        date = _daily_value_date(value)
        if date:
            result.setdefault(date, {})["respiratory_rate"] = round(
                float(value.get("breathsPerMinute", 0)), 1
            )

    for point in temperature_points:
        value = point.get("dailySleepTemperatureDerivations", {})
        date = _daily_value_date(value)
        if date:
            nightly = float(value.get("nightlyTemperatureCelsius", 0))
            baseline = float(value.get("baselineTemperatureCelsius", 0))
            result.setdefault(date, {}).update({
                "skin_temperature_delta_c": round(nightly - baseline, 2),
                "skin_temperature_nightly_c": round(nightly, 2),
                "skin_temperature_baseline_c": round(baseline, 2),
            })

    for point in hrv_points or []:
        value = point.get("dailyHeartRateVariability", {})
        date = _daily_value_date(value)
        if date:
            result.setdefault(date, {}).update({
                "hrv": round(float(value.get("averageHeartRateVariabilityMilliseconds", 0))),
                "non_rem_heart_rate": int(value.get("nonRemHeartRateBeatsPerMinute", 0) or 0),
            })

    for point in resting_hr_points or []:
        value = point.get("dailyRestingHeartRate", {})
        date = _daily_value_date(value)
        if date:
            result.setdefault(date, {})["resting_hr"] = int(
                value.get("beatsPerMinute", 0) or 0
            )

    return result


_TODAY_ROLLUPS = {
    "steps": ("steps", "steps", "countSum"),
    "distance_km": ("distance", "distance", "millimetersSum"),
    "calories_burned": ("active-energy-burned", "activeEnergyBurned", "kcalSum"),
}
_TODAY_HEART_METRICS = {
    "resting_hr": ("daily-resting-heart-rate", "dailyRestingHeartRate", "beatsPerMinute"),
    "hrv": ("daily-heart-rate-variability", "dailyHeartRateVariability", "averageHeartRateVariabilityMilliseconds"),
}


async def get_today_metric(field: str, today: str) -> dict:
    """Fetch just the Google Health source needed for one dashboard value."""
    if field in _TODAY_ROLLUPS:
        source, kind, key = _TODAY_ROLLUPS[field]
        value = _extract_rollup(await _daily_rollup(source, 1), today, kind, key)
        if field == "distance_km":
            return {field: round(value / 1_000_000, 1)}
        return {field: int(value) if field == "steps" else round(value)}
    if field == "active_minutes":
        return {field: _exercise_minutes_by_date(await _list_exercises(1)).get(today, 0)}
    if field == "sleep_hours":
        sessions = await _list_sleep(2)
        hours = max(
            (duration for date, duration, nap in map(_sleep_date_and_hours, sessions)
             if date == today and not nap and duration > 0),
            default=0,
        )
        return {field: hours, "sleep_quality": _sleep_quality(hours)}

    source, kind, key = _TODAY_HEART_METRICS[field]
    points = await _list_daily(source, 1)
    for point in reversed(points):
        value = point.get(kind, {})
        if _daily_value_date(value) == today:
            return {field: int(float(value.get(key, 0)))}
    return {field: 0}


async def get_today_metrics() -> dict:
    """Fetch the complete daily summary for existing callers."""
    today = datetime.now().strftime("%Y-%m-%d")
    fields = (*_TODAY_ROLLUPS, *_TODAY_HEART_METRICS, "active_minutes", "sleep_hours")
    results = await asyncio.gather(*(get_today_metric(field, today) for field in fields))
    metrics = {"date": today}
    for result in results:
        metrics.update(result)
    return metrics


async def get_history_metrics(days: int) -> list:
    """Fetch multiple days of metrics from Google Health API."""
    days = max(1, min(int(days), 366))
    (
        steps_data,
        distance_data,
        calories_data,
        exercise_data,
        rhr_data,
        hrv_data,
        sleep_data,
    ) = await asyncio.gather(
        _daily_rollup("steps", days),
        _daily_rollup("distance", days),
        _daily_rollup("active-energy-burned", days),
        _list_exercises(days),
        _list_daily("daily-resting-heart-rate", days),
        _list_daily("daily-heart-rate-variability", days),
        _list_sleep(days + 1),
    )

    # Build date dict
    result = {}
    for i in range(days):
        d = (datetime.now() - timedelta(days=i)).strftime("%Y-%m-%d")
        result[d] = {
            "date": d, "steps": 0, "distance_km": 0, "sleep_hours": 0,
            "sleep_quality": "—", "hrv": 0, "resting_hr": 0,
            "calories_burned": 0, "active_minutes": 0,
        }

    # Aggregate dailyRollUp data
    for d, val in _rollup_by_date(steps_data, "steps", "countSum").items():
        if d in result:
            result[d]["steps"] = int(val)

    for d, val in _rollup_by_date(distance_data, "distance", "millimetersSum").items():
        if d in result:
            result[d]["distance_km"] = round(val / 1_000_000, 1)

    for d, val in _rollup_by_date(calories_data, "activeEnergyBurned", "kcalSum").items():
        if d in result:
            result[d]["calories_burned"] = round(val)

    # Active minutes (from exercise/workout durations)
    for d, val in _exercise_minutes_by_date(exercise_data).items():
        if d in result:
            result[d]["active_minutes"] = val

    # RHR
    for pt in rhr_data:
        rhr = pt.get("dailyRestingHeartRate", {})
        d = rhr.get("date", {})
        pt_date = f"{d.get('year')}-{d.get('month', 0):02d}-{d.get('day', 0):02d}" if d else ""
        if pt_date in result:
            result[pt_date]["resting_hr"] = int(rhr.get("beatsPerMinute", 0))

    # HRV
    for pt in hrv_data:
        h = pt.get("dailyHeartRateVariability", {})
        d = h.get("date", {})
        pt_date = f"{d.get('year')}-{d.get('month', 0):02d}-{d.get('day', 0):02d}" if d else ""
        if pt_date in result:
            result[pt_date]["hrv"] = int(float(h.get("averageHeartRateVariabilityMilliseconds", 0)))

    # Sleep: keep the longest non-nap session for each local wake date.
    best_sleep = {}
    for pt in sleep_data:
        date, hours, is_nap = _sleep_date_and_hours(pt)
        if date in result and not is_nap and hours > best_sleep.get(date, 0):
            best_sleep[date] = hours
    for date, hours in best_sleep.items():
        result[date]["sleep_hours"] = hours
        result[date]["sleep_quality"] = _sleep_quality(hours)

    return sorted(result.values(), key=lambda x: x["date"], reverse=True)

async def get_sleep_history(days: int = 14) -> list[dict]:
    """Fetch detailed sleep stages for the past N days."""
    fetched = await asyncio.gather(
        _list_sleep(days),
        _list_daily("daily-oxygen-saturation", days),
        _list_daily("daily-respiratory-rate", days),
        _list_daily("daily-sleep-temperature-derivations", days),
        _list_daily("daily-heart-rate-variability", days),
        _list_daily("daily-resting-heart-rate", days),
        return_exceptions=True,
    )
    if isinstance(fetched[0], Exception):
        raise fetched[0]
    sleep_data = fetched[0]
    optional = [value if isinstance(value, list) else [] for value in fetched[1:]]
    recovery_by_date = _sleep_recovery_by_date(*optional)
    sleep_data.sort(key=lambda x: 0 if x.get("dataSource", {}).get("platform") == "FITBIT" else 1)
    
    result = []
    seen_starts = set()
    
    for pt in sleep_data:
        # Explicitly filter out duplicates synced from FitnessDataSync
        app_info = pt.get("dataSource", {}).get("application", {})
        if app_info.get("packageName") == "com.broadheadsoftware.FitnessDataSync":
            continue

        s = pt.get("sleep", {})
        interval = s.get("interval", {})
        start = interval.get("startTime", "")
        
        if not start or start in seen_starts:
            continue
        seen_starts.add(start)
        
        # A night's sleep belongs to the local date on which the user wakes,
        # matching the summary/dashboard convention used elsewhere.
        d, _, _ = _sleep_date_and_hours(pt)
        if not d:
            d = "Unknown"
            
        stages = sorted(s.get("stages", []), key=lambda stage: stage.get("startTime", ""))
        summary = s.get("summary", {})
        
        total_awake = 0
        total_rem = 0
        total_light = 0
        total_deep = 0
        
        parsed_stages = []
        for stage in stages:
            stage_name = stage.get("type", stage.get("stage", "UNKNOWN")).upper()
            st_str = stage.get("startTime")
            et_str = stage.get("endTime")
            if not st_str or not et_str: continue
            
            try:
                st = datetime.fromisoformat(st_str.replace("Z", "+00:00"))
                et = datetime.fromisoformat(et_str.replace("Z", "+00:00"))
                duration_secs = (et - st).total_seconds()
                
                if stage_name == "AWAKE":
                    total_awake += duration_secs
                elif stage_name == "REM":
                    total_rem += duration_secs
                elif stage_name == "LIGHT":
                    total_light += duration_secs
                elif stage_name == "DEEP":
                    total_deep += duration_secs
                    
                parsed_stages.append({
                    "stage": stage_name,
                    "startTime": st_str,
                    "endTime": et_str,
                    "duration_seconds": duration_secs
                })
            except Exception:
                pass
                
        # Override with Google's own summary if available to exactly match their app
        stages_summary = summary.get("stagesSummary", [])
        awake_periods = 0
        for ss in stages_summary:
            t = ss.get("type", "").upper()
            mins = int(ss.get("minutes", 0))
            if t == "AWAKE":
                total_awake = mins * 60
                awake_periods = int(ss.get("count", 0) or 0)
            elif t == "REM": total_rem = mins * 60
            elif t == "LIGHT": total_light = mins * 60
            elif t == "DEEP": total_deep = mins * 60
            
        if parsed_stages:
            minutes_asleep = int(summary.get("minutesAsleep", 0) or 0)
            minutes_in_bed = int(summary.get("minutesInSleepPeriod", 0) or 0)
            record = {
                "date": d,
                "start_time": interval.get("startTime"),
                "end_time": interval.get("endTime"),
                "start_utc_offset": interval.get("startUtcOffset"),
                "end_utc_offset": interval.get("endUtcOffset"),
                "total_awake_mins": round(total_awake / 60),
                "total_rem_mins": round(total_rem / 60),
                "total_light_mins": round(total_light / 60),
                "total_deep_mins": round(total_deep / 60),
                "minutes_asleep": minutes_asleep,
                "minutes_in_bed": minutes_in_bed,
                "sleep_efficiency_percent": round(minutes_asleep / minutes_in_bed * 100) if minutes_in_bed else None,
                "sleep_latency_minutes": int(summary.get("minutesToFallAsleep", 0) or 0),
                "minutes_after_wakeup": int(summary.get("minutesAfterWakeUp", 0) or 0),
                "awake_periods": awake_periods,
                "short_awakenings": len(s.get("shortAwakenings", [])),
                "is_nap": bool(s.get("metadata", {}).get("nap", False)),
                "stages": parsed_stages
            }
            if not record["is_nap"]:
                record.update(recovery_by_date.get(d, {}))
            result.append(record)
            
    cutoff = (datetime.now() - timedelta(days=max(0, days - 1))).strftime("%Y-%m-%d")
    result = [item for item in result if item.get("date", "") >= cutoff]
    return sorted(result, key=lambda x: x["stages"][0]["startTime"], reverse=True)
