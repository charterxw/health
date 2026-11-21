"""Girths and protein logged on the phone, kept on the server.

The phone writes each girth reading by its own id and each day's protein total as an
absolute value, so retries are idempotent. Photos stay on the phone.
"""
from datetime import date, datetime, timedelta, timezone
from typing import Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from .database import get_db

router = APIRouter(prefix='/api/body', tags=['body'])
KINDS = ('waist', 'arm', 'shoulder')
SCHEMA = '''
CREATE TABLE IF NOT EXISTS body_measurements (
 id TEXT PRIMARY KEY, kind TEXT NOT NULL, date TEXT NOT NULL, cm REAL NOT NULL, updated_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS body_measurements_date ON body_measurements(date);
CREATE TABLE IF NOT EXISTS body_protein (date TEXT PRIMARY KEY, grams REAL NOT NULL, updated_at TEXT NOT NULL);
'''


def schema(conn):
    conn.executescript(SCHEMA)


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')


def valid_day(value):
    try:
        return date.fromisoformat(value).isoformat() == value
    except (TypeError, ValueError):
        return False


class Measurement(BaseModel):
    model_config = ConfigDict(extra='forbid')
    kind: Literal['waist', 'arm', 'shoulder']
    date: str = Field(min_length=10, max_length=10)
    cm: float = Field(ge=10, le=300)


class Protein(BaseModel):
    model_config = ConfigDict(extra='forbid')
    grams: float = Field(ge=0, le=1000)


def snapshot():
    with get_db() as conn:
        schema(conn)
        rows = conn.execute('SELECT id, kind, date, cm FROM body_measurements ORDER BY date, id').fetchall()
        protein = conn.execute('SELECT date, grams FROM body_protein ORDER BY date').fetchall()
        conn.commit()
    return {'measurements': [{'id': r[0], 'kind': r[1], 'date': r[2], 'cm': r[3]} for r in rows],
            'protein': {r[0]: r[1] for r in protein}}


@router.get('')
def read_body():
    return snapshot()


@router.put('/measurements/{entry_id}')
def save_measurement(entry_id: str, value: Measurement):
    if not 1 <= len(entry_id) <= 64 or not valid_day(value.date):
        raise HTTPException(422, '请填写有效的日期和编号')
    with get_db() as conn:
        schema(conn)
        conn.execute('INSERT INTO body_measurements VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET '
                     'kind=excluded.kind, date=excluded.date, cm=excluded.cm, updated_at=excluded.updated_at',
                     (entry_id, value.kind, value.date, round(value.cm, 1), stamp()))
        conn.commit()
    return snapshot()


@router.delete('/measurements/{entry_id}')
def delete_measurement(entry_id: str):
    with get_db() as conn:
        schema(conn)
        conn.execute('DELETE FROM body_measurements WHERE id=?', (entry_id,))
        conn.commit()
    return snapshot()


@router.put('/protein/{day}')
def save_protein(day: str, value: Protein):
    if not valid_day(day):
        raise HTTPException(422, '请填写有效的日期')
    with get_db() as conn:
        schema(conn)
        if value.grams > 0:
            conn.execute('INSERT INTO body_protein VALUES (?,?,?) ON CONFLICT(date) DO UPDATE SET '
                         'grams=excluded.grams, updated_at=excluded.updated_at', (day, round(value.grams, 1), stamp()))
        else:
            conn.execute('DELETE FROM body_protein WHERE date=?', (day,))
        conn.commit()
    return snapshot()


def weekly_summary(start, end):
    """Girth changes and protein logging for the week [start, end], for the weekly observation.

    Only what was recorded: a girth change needs a reading in the week and one at least
    25 days before it; protein counts the days that were logged, not the days missed.
    """
    data = snapshot()
    girths = {}
    for kind in KINDS:
        rows = sorted((r for r in data['measurements'] if r['kind'] == kind), key=lambda r: r['date'])
        latest = next((r for r in reversed(rows) if start <= r['date'] <= end), None)
        if not latest:
            continue
        limit = (date.fromisoformat(latest['date']) - timedelta(days=25)).isoformat()
        older = next((r for r in reversed(rows) if r['date'] <= limit), None)
        girths[kind] = {'date': latest['date'], 'cm': latest['cm'],
                        'change_cm': round(latest['cm'] - older['cm'], 1) if older else None,
                        'compared_with': older['date'] if older else None}
    logged = {d: g for d, g in data['protein'].items() if start <= d <= end}
    return {'girths_cm': girths,
            'protein_logged_days': len(logged),
            'protein_grams_by_day': logged,
            'notes': '围度为手工软尺测量，腰围每周、臂围和肩围每月；蛋白质为自记份量估算，未记录的日子不代表没吃。'}
