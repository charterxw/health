"""Observed record times and tracker sync times; never use rollup bucket bounds."""
import asyncio
import math
from datetime import datetime, timedelta, timezone
import httpx
from . import google_health as gh

FAMILY = 'users/me/dataSourceFamilies/google-wearables'
TYPES = [('steps', 'steps', 'steps'), ('activity', 'active-energy-burned', 'activeEnergyBurned')]


def timestamp(value):
    try:
        result = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return result if result.tzinfo else None
    except (ValueError, TypeError, AttributeError):
        return None


def latest_observation(points, key, reference):
    times = []
    for point in points:
        measurement = point.get(key, {})
        interval = measurement.get('interval', {})
        value = measurement.get('count' if key == 'steps' else 'kcal')
        try:
            if value is None or not math.isfinite(float(value)) or float(value) < 0:
                continue
        except (TypeError, ValueError):
            continue
        start, end = timestamp(interval.get('startTime')), timestamp(interval.get('endTime'))
        if start and end and start < end <= reference:
            times.append(end)
    return max(times).isoformat() if times else None


def tracker_summary(devices, reference):
    safe = []
    for device in devices:
        synced = timestamp(device.get('lastSyncTime'))
        if device.get('deviceType') != 'TRACKER' or not synced or synced > reference:
            continue
        safe.append({'name': device.get('deviceVersion') or 'Fitbit', 'last_sync_at': synced.isoformat()})
    if not safe:
        return {'status':'empty','devices':[]}
    air = [d for d in safe if 'air' in d['name'].casefold().split()]
    selected = max(air or safe, key=lambda d: timestamp(d['last_sync_at']))
    return {'status':'ready','device_name':selected['name'],'last_sync_at':selected['last_sync_at'],'devices':safe}


async def freshness_snapshot(reference, previous=None):
    previous = previous or {}
    checked = reference.isoformat()

    async def records(label, data_type, key):
        snake = data_type.replace('-', '_')
        start = (reference-timedelta(days=2)).astimezone(timezone.utc).isoformat()
        end = reference.astimezone(timezone.utc).isoformat()
        try:
            result = await gh._api_get(f'{gh.HEALTH_API_BASE}/users/me/dataTypes/{data_type}/dataPoints',
                {'pageSize':25, 'filter':f'{snake}.interval.start_time >= "{start}" AND {snake}.interval.start_time < "{end}"',
                 'dataSourceFamily':FAMILY})
            latest = latest_observation(result.get('dataPoints', []), key, reference)
            return label, {'status':'ready' if latest else 'empty','observed_at':latest,'fetched_at':checked}
        except Exception:
            old = previous.get('records', {}).get(label)
            return label, {**old, 'status':'stale'} if old and old.get('observed_at') else {'status':'unavailable','observed_at':None}

    async def tracker():
        old = previous.get('device', {})
        last = timestamp(old.get('checked_at'))
        # No repeated denied requests while the user has not enabled the scope.
        if old.get('status') == 'permission_required' and last and reference-last < timedelta(minutes=30):
            return old
        try:
            response = await gh._api_get(f'{gh.HEALTH_API_BASE}/users/me/pairedDevices',
                {'pageSize':100}, paginate=True, collection='pairedDevices')
            return {**tracker_summary(response.get('pairedDevices', []), reference), 'checked_at':checked}
        except httpx.HTTPStatusError as error:
            try:
                reasons = {d.get('reason') for d in error.response.json().get('error', {}).get('details', [])}
            except (ValueError, TypeError):
                reasons = set()
            if error.response.status_code == 403 and reasons & {'MISSING_OAUTH_SCOPE', 'ACCESS_TOKEN_SCOPE_INSUFFICIENT'}:
                return {'status':'permission_required','checked_at':checked}
            return {**old, 'status':'stale' if old.get('last_sync_at') else 'unavailable','checked_at':checked}
        except Exception:
            return {**old, 'status':'stale' if old.get('last_sync_at') else 'unavailable','checked_at':checked}

    results = await asyncio.gather(*(records(*spec) for spec in TYPES), tracker())
    return {'checked_at':checked, 'records':dict(results[:-1]), 'device':results[-1]}
