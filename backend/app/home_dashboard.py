"""Personal home: source snapshots, dated goals and plan-linked progress.

No external AI calls. Raw Google snapshots and user feedback are kept apart;
derived values are rebuilt after every read so edits/deletions are reflected.
"""
import asyncio
import json
import math
import os
import statistics
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field
from typing import Literal
from .database import get_db
from . import google_health as gh
from .data_freshness import freshness_snapshot

router = APIRouter(prefix='/api/home', tags=['home'])
TZ = ZoneInfo(os.getenv('TZ', 'America/New_York'))
FAMILY = 'users/me/dataSourceFamilies/google-wearables'
COMPANY = ['guided-upper-a', 'guided-lower-a', 'guided-upper-b', 'guided-lower-b']
HOME = ['personal-home-a', 'personal-home-b', 'personal-home-c', 'personal-home-d']
SHORT = ['胸', '背', '上', '背']
_lock = asyncio.Lock()


def schema(conn):
    conn.executescript('''
    CREATE TABLE IF NOT EXISTS home_snapshots (key TEXT PRIMARY KEY, document TEXT NOT NULL, fetched_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS home_goals (effective_date TEXT PRIMARY KEY, document TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS home_feedback (date TEXT PRIMARY KEY, energy TEXT, fatigue TEXT, posture INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS home_rounds (id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, document TEXT NOT NULL, closed INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS home_plan_links (session_id TEXT PRIMARY KEY, round_id INTEGER NOT NULL, slot INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS home_plan_allocations (session_id TEXT NOT NULL, round_id INTEGER NOT NULL, slot INTEGER NOT NULL, PRIMARY KEY(session_id,round_id,slot));
    CREATE TABLE IF NOT EXISTS home_plan_ignored (session_id TEXT PRIMARY KEY);
    CREATE TABLE IF NOT EXISTS home_activity_edits (id TEXT PRIMARY KEY, document TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS home_step_goal (id INTEGER PRIMARY KEY CHECK(id=1), target INTEGER NOT NULL, basis TEXT NOT NULL);
    ''')


def now():
    return datetime.now(TZ)


def parse(value):
    try:
        result = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return result if result.tzinfo else None
    except (ValueError, TypeError, AttributeError):
        return None


def monday(day):
    return day - timedelta(days=day.weekday())


def snapshot(key):
    with get_db() as conn:
        schema(conn)
        row = conn.execute('SELECT document, fetched_at FROM home_snapshots WHERE key=?', (key,)).fetchone()
    return (json.loads(row[0]), row[1]) if row else (None, None)


def save_snapshot(key, document):
    with get_db() as conn:
        schema(conn)
        conn.execute('INSERT INTO home_snapshots VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET document=excluded.document,fetched_at=excluded.fetched_at',
                     (key, json.dumps(document, ensure_ascii=False), now().isoformat()))
        conn.commit()


def is_posture_movement(movement):
    return movement.get('training_type') == 'mobility' or (movement.get('exercise_id') or '').startswith('posture-')


def is_strength_session(session):
    return session.get('status') != 'discarded' and any(not is_posture_movement(m) for m in session.get('exercises', []))


def completed_posture_sets(session):
    if session.get('status') != 'completed':
        return []
    return [(m, s) for m in session.get('exercises', []) if is_posture_movement(m)
            for s in m.get('sets', []) if parse(s.get('completed_at')) and not s.get('warmup')
            and ((s.get('duration_seconds') if m.get('tracking') == 'duration' else s.get('reps')) or 0) > 0]


def completed_sets(session):
    return [(m, s) for m in session.get('exercises', []) for s in m.get('sets', [])
            if not is_posture_movement(m) and s.get('completed_at') and not s.get('warmup')
            and ((s.get('duration_seconds') if m.get('tracking') == 'duration' else s.get('reps')) or 0) > 0]


def load_training():
    with get_db() as conn:
        schema(conn)
        sessions = [json.loads(r[0]) for r in conn.execute("SELECT document_json FROM strength_sessions WHERE status != 'discarded' ORDER BY started_at")]
        templates = {r[0]: json.loads(r[1]) for r in conn.execute('SELECT id,document_json FROM strength_templates')}
    return sessions, templates


def merged_intervals(intervals):
    merged = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    return merged


def training_windows(sessions, day, cutoff):
    start = datetime.combine(day, datetime.min.time(), TZ)
    end = min(start + timedelta(days=1), cutoff)
    intervals, reliable = [], True
    for session in sessions:
        if not is_strength_session(session):
            continue
        a, b = parse(session.get('started_at')), parse(session.get('ended_at'))
        if not a:
            continue
        b = b or cutoff
        if a < end and b > start:
            if b <= a or b - a > timedelta(hours=6):
                reliable = False
                continue
            intervals.append((max(start, a), min(end, b)))
    return merged_intervals(intervals), reliable


def energy_sum(points):
    values = [p.get('activeEnergyBurned', {}).get('kcalSum') for p in points]
    values = [float(v) for v in values if v is not None and math.isfinite(float(v))]
    return sum(values) if values else None


async def roll_energy(start, end):
    data = await gh._api_post(f'{gh.HEALTH_API_BASE}/users/me/dataTypes/active-energy-burned/dataPoints:rollUp',
        {'range': {'startTime': start.astimezone(timezone.utc).isoformat(), 'endTime': end.astimezone(timezone.utc).isoformat()},
         'windowSize': f'{max(60, math.ceil((end-start).total_seconds()))}s', 'dataSourceFamily': FAMILY})
    return energy_sum(data.get('rollupDataPoints', []))


async def activity_snapshot(sessions):
    cutoff = now()
    semaphore = asyncio.Semaphore(4)

    async def one(day):
        async with semaphore:
            start = datetime.combine(day, datetime.min.time(), TZ)
            end = min(start + timedelta(days=1), cutoff)
            intervals, reliable = training_windows(sessions, day, cutoff)
            signature = [[a.isoformat(), b.isoformat()] for a, b in intervals]
            try:
                total = await roll_energy(start, end)
                work = [await roll_energy(a, b) for a, b in intervals]
                valid = reliable and total is not None and all(v is not None for v in work)
                deducted = sum(v for v in work if v is not None)
                valid = valid and deducted <= total + 1
                return {'date': day.isoformat(), 'total': round(total) if total is not None else None,
                        'strength': round(deducted) if valid else None,
                        'activity': max(0, round(total-deducted)) if valid else None,
                        'windows': signature, 'cutoff': end.isoformat()}
            except Exception:
                return {'date': day.isoformat(), 'activity': None, 'total': None, 'windows': signature}
    # Complete recent weeks establish targets from the same energy definition.
    return await asyncio.gather(*(one(cutoff.date()-timedelta(days=i)) for i in range(28)))


def merge_activity_snapshot(previous, current):
    """Keep the last measured value on a transient miss, only for identical windows."""
    old = {row['date']: row for row in previous or []}
    return [old[row['date']] if row.get('activity') is None
            and old.get(row['date'], {}).get('activity') is not None
            and old[row['date']].get('windows') == row.get('windows') else row
            for row in current]


async def weight_snapshot():
    start = (now()-timedelta(days=90)).astimezone(timezone.utc).isoformat()
    result = await gh._api_get(f'{gh.HEALTH_API_BASE}/users/me/dataTypes/weight/dataPoints',
        {'filter': f'weight.sample_time.physical_time >= "{start}"', 'pageSize': 1000}, paginate=True)
    daily = {}
    for point in result.get('dataPoints', []):
        w = point.get('weight', {})
        t = parse(w.get('sampleTime', {}).get('physicalTime'))
        grams = w.get('weightGrams')
        if not t or not isinstance(grams, (int, float)) or not 10000 < grams < 500000:
            continue
        key = t.astimezone(TZ).date().isoformat()
        if key not in daily or t.isoformat() > daily[key]['time']:
            daily[key] = {'date': key, 'kg': round(grams / 1000, 2), 'time': t.isoformat()}
    return sorted(daily.values(), key=lambda x: x['date'], reverse=True)


async def walk_snapshot():
    points = await gh._list_exercises(28)
    result = []
    for point in points:
        ex = point.get('exercise', {})
        title = str(ex.get('name') or ex.get('activityName') or ex.get('type') or ex.get('exerciseType') or '')
        # Read native walk records first; do not invent a walk from elevated HR.
        if 'walk' not in title.lower() and '步行' not in title:
            continue
        interval = ex.get('interval', {})
        a, b = parse(interval.get('startTime')), parse(interval.get('endTime'))
        if not a or not b or a >= b:
            continue
        result.append({'id': point.get('name') or a.isoformat(), 'date': a.astimezone(TZ).date().isoformat(),
                       'start': a.isoformat(), 'end': b.isoformat(), 'title': title})
    unique = {(x['start'], x['end']): x for x in result}
    return sorted(unique.values(), key=lambda x: x['start'], reverse=True)


async def refresh():
    if not gh.is_authenticated():
        raise HTTPException(409, 'Google Health 未连接')
    async with _lock:
        _, last = snapshot('metrics')
        sessions, _ = load_training()
        previous_freshness, freshness_read = snapshot('freshness')
        read_freshness = not freshness_read or (now()-parse(freshness_read)).total_seconds() >= 90
        recent = bool(last and (now()-parse(last)).total_seconds() < 90)
        activity_valid = False
        if recent:
            activity, _ = snapshot('activity')
            cached = next((row for row in activity or [] if row['date'] == now().date().isoformat()), {})
            cutoff = parse(cached.get('cutoff')) or now()
            windows, reliable = training_windows(sessions, now().date(), cutoff)
            signature = [[a.isoformat(), b.isoformat()] for a, b in windows]
            if reliable and cached.get('activity') is not None and cached.get('windows') == signature:
                activity_valid = True
        async def collect(key, call):
            try:
                data = await asyncio.wait_for(call, timeout=65)
                if key == 'activity':
                    data = merge_activity_snapshot(snapshot('activity')[0], data)
                # An entirely failed split must not erase the last reliable snapshot.
                if key == 'activity' and not any(x.get('activity') is not None for x in data):
                    return key
                save_snapshot(key, data)
            except Exception as e:
                print('Home source refresh:', key, type(e).__name__)
                return key
        if recent:
            jobs = [] if activity_valid else [collect('activity', activity_snapshot(sessions))]
        else:
            jobs = [collect('metrics', gh.get_history_metrics(35)),
            collect('sleep', gh.get_sleep_history(14)), collect('weight', weight_snapshot()),
            collect('activity', activity_snapshot(sessions)), collect('walks', walk_snapshot())]
        if read_freshness:
            jobs.append(collect('freshness', freshness_snapshot(now(), previous_freshness)))
        return await asyncio.gather(*jobs) if jobs else None


def plan_state(sessions, templates):
    ids = [x for pair in zip(COMPANY, HOME) for x in pair]
    with get_db() as conn:
        schema(conn)
        current = conn.execute('SELECT * FROM home_rounds WHERE closed=0 ORDER BY id DESC LIMIT 1').fetchone()
        if not current and all(x in templates for x in ids):
            slots = [{'template_id': x, 'name': templates[x]['name'], 'short': '家' if i % 2 else SHORT[i//2],
                      'exercises': [{'exercise_id': m['exercise_id'], 'target': m['set_count'] - (m.get('warmup_count') or 0)}
                                    for m in templates[x]['exercises']]} for i, x in enumerate(ids)]
            conn.execute('INSERT INTO home_rounds(created_at,document) VALUES (?,?)', (now().isoformat(), json.dumps(slots, ensure_ascii=False)))
            current = conn.execute('SELECT * FROM home_rounds ORDER BY id DESC LIMIT 1').fetchone()
        if not current:
            return None
        slots = json.loads(current['document'])
        # Known template identity is safe to link; unrelated historical workouts remain separate.
        linked = {r[0] for r in conn.execute('SELECT session_id FROM home_plan_allocations UNION SELECT session_id FROM home_plan_ignored')}
        for session in sessions:
            if session['id'] in linked or session.get('template_id') not in ids or not completed_sets(session):
                continue
            if (parse(session.get('started_at')) or now()) < parse(current['created_at']):
                continue
            slot = ids.index(session['template_id'])
            conn.execute('INSERT OR IGNORE INTO home_plan_allocations VALUES (?,?,?)', (session['id'], current['id'], slot))
        links = [(r[0], r[1]) for r in conn.execute('SELECT session_id,slot FROM home_plan_allocations WHERE round_id=?', (current['id'],))]
        conn.commit()
    used = set()
    finished_sessions = {s['id'] for s in sessions if s.get('status') == 'completed' and completed_sets(s)}
    for i, slot in enumerate(slots):
        counts = {}
        quotas = {m['exercise_id']: m['target'] for m in slot['exercises']}
        for session in sessions:
            if (session['id'], i) not in links:
                continue
            for movement, item in completed_sets(session):
                key = movement['exercise_id']
                token = (session['id'], item['id'])
                if token in used or counts.get(key, 0) >= quotas.get(key, 0):
                    continue
                counts[key] = counts.get(key, 0) + 1
                used.add(token)
        slot['done'] = sum(min(m['target'], counts.get(m['exercise_id'], 0)) for m in slot['exercises'])
        slot['target'] = sum(m['target'] for m in slot['exercises'])
        slot['remaining'] = [{**m, 'target': max(0, m['target']-counts.get(m['exercise_id'], 0))} for m in slot['exercises']]
        slot['remaining'] = [m for m in slot['remaining'] if m['target']]
        confirmation = slot.get('completion_confirmation') or {}
        references = confirmation.get('session_ids') or []
        slot['completion_confirmed'] = bool(references and set(references) <= finished_sessions)
        slot['completed'] = slot['done'] >= slot['target'] or slot['completion_confirmed']
    result = {'id': current['id'], 'slots': slots, 'done': sum(s['done'] for s in slots), 'target': sum(s['target'] for s in slots),
              'next': next((s for s in slots if not s['completed']), None), 'links': links}
    schedule = [{'letter': letter, 'day': day, 'optional': False, 'slots': slots[i*2:i*2+2]}
                for i, (letter, day) in enumerate([('A',1),('B',2),('C',4),('D',5)])]
    e_ids = ['personal-company-e', 'personal-home-e']
    if all(key in templates for key in e_ids):
        optional_slots = []
        for key in e_ids:
            t = templates[key]
            counts = {}
            for session in sessions:
                if session.get('template_id') != key or session.get('status') == 'discarded' or (parse(session.get('started_at')) or now()) < parse(current['created_at']):
                    continue
                for movement, item in completed_sets(session):
                    ident = movement['exercise_id']
                    counts[ident] = counts.get(ident, 0) + 1
            remaining = [{'exercise_id': m['exercise_id'], 'target': max(0,m['set_count']-(m.get('warmup_count') or 0)-counts.get(m['exercise_id'],0))} for m in t['exercises']]
            target = sum(m['set_count']-(m.get('warmup_count') or 0) for m in t['exercises'])
            done = target-sum(m['target'] for m in remaining)
            optional_slots.append({'template_id':key,'name':t['name'],'short':'腹','optional':True,'target':target,'done':done,
                                   'completed':done>=target,'remaining':[m for m in remaining if m['target']]})
        schedule.insert(2, {'letter':'E','day':3,'optional':True,'slots':optional_slots})
    result['schedule'] = schedule
    result['current'] = next((day for day in schedule if result['next'] in day['slots']), None)
    # E is available between B and C, without blocking Thursday or a started C.
    e = next((day for day in schedule if day['optional']), None)
    c_started = any(s.get('template_id') in [COMPANY[2],HOME[2]] and
                    (s.get('status') == 'active' or completed_sets(s)) and
                    (parse(s.get('started_at')) or now()) >= parse(current['created_at']) for s in sessions)
    if e and all(s['completed'] for s in slots[:4]) and result['next'] in slots[4:6] and now().weekday() == 2 and not c_started and not all(s['completed'] for s in e['slots']):
        result['current'] = e
    return result


def initial_goals(activity):
    vals = [r['activity'] for r in activity if r.get('activity') is not None and r['date'] < now().date().isoformat()]
    daily = max(50, int(round(statistics.median(vals)/25)*25)) if len(vals) >= 10 else 300
    return {'dailyActivity': daily, 'weeklyActivity': daily*7, 'weeklyStrength': 4, 'weeklyPosture': 4,
            'basis': '近几周日常活动' if len(vals) >= 10 else '可调整的初始目标'}


def step_goal(conn, metrics):
    """Initialize once from complete recent days; refreshes never move the target."""
    row = conn.execute('SELECT target,basis FROM home_step_goal WHERE id=1').fetchone()
    if row:
        return dict(row)
    current = now().date()
    days = {r['date']: r['steps'] for r in metrics
            if (current-timedelta(days=28)).isoformat() <= r.get('date', '') < current.isoformat()
            and isinstance(r.get('steps'), (int, float)) and math.isfinite(r['steps']) and r['steps'] >= 0}
    target = max(1000, min(50000, int(round(statistics.median(days.values())/500)*500))) if len(days) >= 7 else 7000
    basis = f'根据近28天内{len(days)}个完整日的步数中位数初始化，取整到500步。' if len(days) >= 7 else '可调整的初始目标；积累至少7个完整日后，可参考自己的日常水平调整。'
    conn.execute('INSERT OR IGNORE INTO home_step_goal VALUES (1,?,?)', (target, basis))
    return dict(conn.execute('SELECT target,basis FROM home_step_goal WHERE id=1').fetchone())


SLEEP_TARGET_HOURS = 8.0


def _positive(rows, key):
    return [r[key] for r in rows if isinstance(r.get(key), (float, int)) and r[key] > 0]


def readiness(today, metrics):
    """Recovery against the person's own normal range (personal-v2).

    HRV is compared on a log scale and resting heart rate in beats, each as a
    z-score against the previous 28 days; half of each signal is last night and
    half the 7-day rolling mean, so one noisy night cannot swing the result.
    Sleep compares last night and the 7-night average with an 8-hour target.
    Within half a standard deviation of normal reads as 平稳.
    """
    previous = [x for x in metrics if x['date'] < today['date']]
    history = previous[:28]
    hrvs, rhrs = _positive(history, 'hrv'), _positive(history, 'resting_hr')
    if len(hrvs) < 7 or len(rhrs) < 7 or any(not today.get(k) for k in ['sleep_hours', 'hrv', 'resting_hr']):
        return {'score': None, 'label': '待更新', 'version': 'personal-v2'}
    clamp = lambda v, lo, hi: min(hi, max(lo, v))
    logs = [math.log(v) for v in hrvs]
    hrv_mean, hrv_sd = statistics.mean(logs), max(statistics.pstdev(logs), 0.08)
    rhr_mean, rhr_sd = statistics.mean(rhrs), max(statistics.pstdev(rhrs), 2.5)
    week = [today, *previous[:6]]
    week_hrv = statistics.mean(math.log(v) for v in _positive(week, 'hrv'))
    week_rhr = statistics.mean(_positive(week, 'resting_hr'))
    hrv_z = clamp(.5*(math.log(today['hrv'])-hrv_mean)/hrv_sd + .5*(week_hrv-hrv_mean)/hrv_sd, -3, 3)
    rhr_z = clamp(.5*(rhr_mean-today['resting_hr'])/rhr_sd + .5*(rhr_mean-week_rhr)/rhr_sd, -3, 3)
    # A fixed target rather than the recent median: the median follows late nights
    # and would make short sleep look normal.
    need = SLEEP_TARGET_HOURS
    nights = _positive(week, 'sleep_hours')
    debt = sum(max(0, need-h) for h in nights) / len(nights)
    sleep_z = clamp(.7*clamp((today['sleep_hours']-need)/.75, -3, 1.5) - .3*debt/.75, -3, 1.5)
    z = .4*hrv_z + .25*rhr_z + .35*sleep_z
    score = round(clamp(70 + 16*z, 0, 100))
    # Short sleep cannot be offset by heart signals that look normal.
    if today['sleep_hours'] < 5.5:
        score = min(score, 61)
    elif today['sleep_hours'] < 6.5:
        score = min(score, 77)
    label = '充分' if score >= 78 else '平稳' if score >= 62 else '偏低'
    def weak(r):
        return bool(r.get('hrv') and r.get('resting_hr') and (math.log(r['hrv'])-hrv_mean)/hrv_sd < -1 and (r['resting_hr']-rhr_mean)/rhr_sd > 1)
    caution = sum(weak(r) for r in week[:3]) >= 2
    return {'score': score, 'label': label, 'caution': caution, 'version': 'personal-v2',
            'hrv_baseline': round(math.exp(hrv_mean), 1), 'rhr_baseline': round(rhr_mean, 1),
            'hrv_range': [round(math.exp(hrv_mean-.5*hrv_sd), 1), round(math.exp(hrv_mean+.5*hrv_sd), 1)],
            'rhr_range': [round(rhr_mean-.5*rhr_sd, 1), round(rhr_mean+.5*rhr_sd, 1)],
            'sleep_need': round(need, 1), 'sleep_debt': round(debt, 1),
            'components': {'hrv': round(hrv_z, 2), 'resting_hr': round(rhr_z, 2), 'sleep': round(sleep_z, 2)}}


def summary():
    current = now().date()
    week = monday(current)
    sources = {k: snapshot(k) for k in ['metrics', 'sleep', 'weight', 'activity', 'walks']}
    metrics, sleeps, weights, activity, walks = [sources[k][0] or [] for k in sources]
    sessions, templates = load_training()
    strength_sessions = [s for s in sessions if is_strength_session(s)]
    plan = plan_state(sessions, templates)
    with get_db() as conn:
        schema(conn)
        steps_goal = step_goal(conn, metrics)
        if activity and not conn.execute('SELECT 1 FROM home_goals LIMIT 1').fetchone():
            conn.execute('INSERT INTO home_goals VALUES (?,?)', (week.isoformat(), json.dumps(initial_goals(activity))))
        versions = [(r[0], json.loads(r[1])) for r in conn.execute('SELECT * FROM home_goals ORDER BY effective_date')]
        feedback = {r['date']: dict(r) for r in conn.execute('SELECT * FROM home_feedback')}
        edits = {r[0]: json.loads(r[1]) for r in conn.execute('SELECT * FROM home_activity_edits')}
        conn.commit()
    if not versions:
        versions = [(week.isoformat(), initial_goals(activity))]
    goal_at = lambda d: next((g for start, g in reversed(versions) if start <= d), versions[0][1])
    mapped = {r['date']: r for r in metrics}
    energies = {r['date']: r for r in activity}
    rows = []
    for i in range(7):
        day = week + timedelta(days=i)
        key = day.isoformat()
        on_day = lambda item: bool(parse(item.get('completed_at')) and parse(item['completed_at']).astimezone(TZ).date() == day)
        daily_sessions = [s for s in strength_sessions if parse(s.get('started_at')) and (parse(s['started_at']).astimezone(TZ).date() == day or any(on_day(item) for _, item in completed_sets(s)))]
        posture_sessions = [s for s in sessions if any(on_day(item) for _, item in completed_posture_sets(s))]
        done = sum(sum(on_day(item) for _, item in completed_sets(s)) for s in daily_sessions)
        target = sum(sum(not is_posture_movement(m) and not x.get('warmup') and (on_day(x) or not x.get('completed_at') and parse(s['started_at']).astimezone(TZ).date() == day) for m in s['exercises'] for x in m['sets']) for s in daily_sessions)
        planned = i in [0, 1, 3, 4] and day >= current
        optional = i == 2 and 'personal-company-e' in templates and 'personal-home-e' in templates
        tag = '休'
        if daily_sessions:
            t = daily_sessions[-1].get('template_id') or ''
            tag = '腹' if t in ['personal-company-e','personal-home-e'] else SHORT[COMPANY.index(t)] if t in COMPANY else '家' if t in HOME or 'weekend' in t else '练'
            if t in COMPANY:
                target += sum(m['set_count']-(m.get('warmup_count') or 0) for m in templates.get(HOME[COMPANY.index(t)], {}).get('exercises', []))
        elif optional:
            tag = '腹'
            target = sum(m['set_count']-(m.get('warmup_count') or 0) for key in ['personal-company-e','personal-home-e'] for m in templates[key]['exercises'])
        elif planned and plan and plan['next']:
            offset = [0, 1, 3, 4].index(i) - sum(x < current.weekday() for x in [0, 1, 3, 4])
            next_index = plan['slots'].index(plan['next'])
            pair = min(3, next_index//2 + max(0, offset))
            tag = SHORT[pair]
            target = sum(s['target'] for s in plan['slots'][pair*2:pair*2+2])
        energy = energies.get(key, {})
        intervals, reliable = training_windows(sessions, day, parse(energy.get('cutoff')) or now()) if day <= current else ([], True)
        signature = [[a.isoformat(), b.isoformat()] for a, b in intervals]
        valid = reliable and energy.get('windows') == signature
        value = energy.get('activity') if valid and day <= current else None
        rows.append({'date': key, 'activity': value, 'total_energy': energy.get('total'), 'strength_energy': energy.get('strength') if valid else None,
                     'cutoff': energy.get('cutoff'), 'sets': done, 'target': target, 'short': tag,
                     'strength_planned': bool(daily_sessions) or planned, 'strength_optional': optional, 'posture': bool(posture_sessions),
                     'posture_recorded': bool(posture_sessions), 'posture_sessions': [{'id': s['id'], 'title': s['title']} for s in posture_sessions],
                     'posture_planned': i in [0, 1, 3, 6], 'goals': goal_at(key), 'sessions': [{'id': s['id'], 'title': s['title']} for s in daily_sessions]})
    today = {'date': current.isoformat(), **mapped.get(current.isoformat(), {})}
    recover = readiness(today, metrics)
    feeling = feedback.get(current.isoformat(), {})
    active = next((s for s in strength_sessions if s['status'] == 'active'), None)
    today_sessions = [s for s in strength_sessions if parse(s['started_at']).astimezone(TZ).date() == current]
    optional_today = bool(current.weekday() == 2 and 'personal-company-e' in templates and 'personal-home-e' in templates)
    current_day = plan and plan.get('current')
    next_slot = next((s for s in current_day['slots'] if not s['completed']),None) if current_day and current_day['optional'] else plan and plan['next']
    tired = feeling.get('energy') == '困倦' or feeling.get('fatigue') == '重' or (today.get('sleep_hours') or 9) < 6 or recover.get('caution')
    trained = any(completed_sets(s) for s in today_sessions)
    if active:
        tip = '先热身看看状态，今天可以适当减量。' if tired else '继续今天的训练，按自己的节奏完成。'
    elif next_slot and next_slot['short'] == '家' and trained:
        tip = '先看热身状态，家庭训练可以适当减量。' if tired else '今天还剩家庭训练，晚上接着完成。'
    elif trained:
        tip = '今天训练已记录，晚上照常遛狗即可。'
    elif tired:
        tip = '今天状态偏疲惫，训练前先热身看看。'
    elif optional_today:
        tip = '今天可选练腹部和小腿，也可以休息，遛狗散步照常。'
    elif current.weekday() in [0, 1, 3, 4]:
        tip = '按原计划训练，遛狗散步照常。'
    else:
        tip = '今天按计划休息，照常遛狗散步。'
    primary_sleep = next((s for s in sleeps if s['date'] == current.isoformat() and not s.get('is_nap')), None)
    # Sleep rows may contain multiple primary sessions; use the longest.
    same = [s for s in sleeps if s['date'] == current.isoformat() and not s.get('is_nap')]
    if same:
        primary_sleep = max(same, key=lambda s: s.get('minutes_asleep', 0))
    for w in walks:
        w.update(edits.get(w['id'], {}))
    return {'date': current.isoformat(), 'timezone': str(TZ), 'today': today, 'days': rows,
            'metrics': metrics, 'sleep': primary_sleep, 'sleeps': sleeps, 'weights': weights, 'walks': walks,
            'recovery': recover, 'feedback': feeling, 'plan': plan, 'tip': tip, 'step_goal': steps_goal,
            'freshness': snapshot('freshness')[0] or {},
            'action': {'session_id': active['id']} if active else {'template_id': next_slot['template_id'], 'remaining': next_slot['remaining']} if next_slot else {},
            'goals': goal_at(current.isoformat()), 'next_goals': next((g for start, g in versions if start > current.isoformat()), None),
            'next_effective': (week+timedelta(days=7)).isoformat(), 'sources': {k: {'fetched_at': v[1]} for k, v in sources.items()}}


class Goals(BaseModel):
    model_config = ConfigDict(extra='forbid')
    dailyActivity: int = Field(ge=1, le=3000)
    weeklyActivity: int = Field(ge=1, le=21000)
    weeklyStrength: int = Field(ge=1, le=7)
    weeklyPosture: int = Field(ge=1, le=7)


class Feedback(BaseModel):
    model_config = ConfigDict(extra='forbid')
    energy: Literal['充沛', '一般', '困倦'] | None = None
    fatigue: Literal['轻', '中', '重'] | None = None


class StepGoal(BaseModel):
    model_config = ConfigDict(extra='forbid')
    target: int = Field(ge=1000, le=50000, strict=True)


@router.put('/step-goal')
def save_step_goal(value: StepGoal):
    with get_db() as conn:
        schema(conn)
        conn.execute('INSERT INTO home_step_goal VALUES (1,?,?) ON CONFLICT(id) DO UPDATE SET target=excluded.target,basis=excluded.basis',
                     (value.target, '自己设定的日常走动目标。'))
        conn.commit()
    return summary()


@router.get('')
async def get_home():
    return summary()


@router.post('/refresh')
async def refresh_home():
    failures = await refresh()
    return {**summary(), 'refresh_failed': [f for f in failures or [] if f]}


@router.put('/goals')
def save_goals(value: Goals):
    # Ensure a current effective version exists before writing a future version.
    baseline = summary()
    effective = monday(now().date())+timedelta(days=7)
    with get_db() as conn:
        schema(conn)
        conn.execute('INSERT OR IGNORE INTO home_goals VALUES (?,?)', (monday(now().date()).isoformat(), json.dumps(baseline['goals'])))
        conn.execute('INSERT INTO home_goals VALUES (?,?) ON CONFLICT(effective_date) DO UPDATE SET document=excluded.document',
                     (effective.isoformat(), json.dumps(value.model_dump())))
        conn.commit()
    return summary()


@router.put('/feedback')
def save_feedback(value: Feedback):
    key = now().date().isoformat()
    with get_db() as conn:
        schema(conn)
        conn.execute('INSERT OR IGNORE INTO home_feedback(date) VALUES (?)', (key,))
        for field in value.model_fields_set:
            conn.execute(f'UPDATE home_feedback SET {field}=? WHERE date=?', (getattr(value, field), key))
        conn.commit()
    return summary()


class WalkEdit(BaseModel):
    id: str = Field(max_length=500)
    start: datetime
    end: datetime
    ignored: bool = False


@router.put('/walk')
def edit_walk(value: WalkEdit):
    original = next((w for w in (snapshot('walks')[0] or []) if w['id'] == value.id), None)
    if not original or value.start.tzinfo is None or value.end.tzinfo is None or not timedelta(0) < value.end-value.start <= timedelta(hours=12):
        raise HTTPException(422, '请选择有效的散步起止时间')
    if value.start.astimezone(TZ).date().isoformat() != original['date']:
        raise HTTPException(422, '请在原记录日期内调整时间')
    doc = {'start': value.start.isoformat(), 'end': value.end.isoformat(), 'ignored': value.ignored}
    with get_db() as conn:
        schema(conn)
        conn.execute('INSERT INTO home_activity_edits VALUES (?,?) ON CONFLICT(id) DO UPDATE SET document=excluded.document', (value.id, json.dumps(doc)))
        conn.commit()
    return summary()


class Link(BaseModel):
    session_id: str = Field(max_length=80)
    slot: int = Field(ge=0, le=7)
    remove: bool = False


@router.put('/plan/link')
def link_session(value: Link):
    sessions, templates = load_training()
    plan = plan_state(sessions, templates)
    if not plan or value.session_id not in {s['id'] for s in sessions}:
        raise HTTPException(422, '训练记录不存在')
    with get_db() as conn:
        if value.remove:
            conn.execute('DELETE FROM home_plan_allocations WHERE session_id=? AND round_id=? AND slot=?', (value.session_id, plan['id'], value.slot))
            conn.execute('INSERT OR IGNORE INTO home_plan_ignored VALUES (?)', (value.session_id,))
        else:
            if conn.execute('SELECT 1 FROM home_plan_allocations WHERE session_id=? AND round_id!=?', (value.session_id, plan['id'])).fetchone():
                raise HTTPException(409, '这次训练已关联其他轮次')
            conn.execute('INSERT OR IGNORE INTO home_plan_allocations VALUES (?,?,?)', (value.session_id, plan['id'], value.slot))
        conn.commit()
    return summary()


@router.post('/plan/next')
def next_round():
    with get_db() as conn:
        schema(conn)
        conn.execute('UPDATE home_rounds SET closed=1 WHERE closed=0')
        conn.commit()
    return summary()
