import sqlite3
import os
from contextlib import contextmanager

DB_PATH = os.getenv("DB_PATH", "fitness.db")


def get_db_path():
    return DB_PATH


@contextmanager
def get_db():
    conn = sqlite3.connect(get_db_path())
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


def init_db():
    with get_db() as conn:
        from .session_review import SCHEMA_SQL
        conn.execute(SCHEMA_SQL)
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS health_metrics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                date TEXT NOT NULL,
                steps INTEGER DEFAULT 0,
                distance_km REAL DEFAULT 0,
                sleep_hours REAL DEFAULT 0,
                sleep_quality TEXT DEFAULT 'unknown',
                hrv INTEGER DEFAULT 0,
                resting_hr INTEGER DEFAULT 0,
                calories_burned INTEGER DEFAULT 0,
                active_minutes INTEGER DEFAULT 0,
                created_at TEXT DEFAULT (datetime('now'))
            );



            CREATE TABLE IF NOT EXISTS ai_insights (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                date TEXT NOT NULL,
                time_slot TEXT NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                category TEXT DEFAULT 'general',
                created_at TEXT DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS training_analysis (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                date TEXT NOT NULL,
                summary TEXT NOT NULL,
                trends TEXT,
                risks TEXT,
                recommendations TEXT,
                created_at TEXT DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS notification_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                event_date TEXT NOT NULL,
                event_key TEXT NOT NULL,
                delivered_at TEXT DEFAULT (datetime('now')),
                UNIQUE(event_date, event_key)
            );

            CREATE TABLE IF NOT EXISTS recorded_sessions (
                id TEXT PRIMARY KEY,
                document_json TEXT NOT NULL,
                version INTEGER NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                heart_rate_json TEXT,
                heart_rate_synced_at TEXT
            );

            CREATE TABLE IF NOT EXISTS strength_exercises (
                id TEXT PRIMARY KEY,
                document_json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS strength_templates (
                id TEXT PRIMARY KEY,
                document_json TEXT NOT NULL,
                version INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS strength_setup_notes (
                exercise_id TEXT PRIMARY KEY,
                note TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS strength_sessions (
                id TEXT PRIMARY KEY,
                document_json TEXT NOT NULL,
                version INTEGER NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT,
                status TEXT NOT NULL
            );
            CREATE UNIQUE INDEX IF NOT EXISTS idx_strength_one_active
            ON strength_sessions((1)) WHERE status = 'active';
            CREATE INDEX IF NOT EXISTS idx_strength_started ON strength_sessions(started_at);
            CREATE TABLE IF NOT EXISTS strength_session_deletions (
                id TEXT PRIMARY KEY,
                version INTEGER NOT NULL,
                deleted_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS strength_physiology (
                session_id TEXT PRIMARY KEY,
                started_at TEXT NOT NULL,
                ended_at TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'queued',
                payload_json TEXT,
                preferred_source_id TEXT,
                attempts INTEGER NOT NULL DEFAULT 0,
                checked_at TEXT,
                next_attempt_at TEXT,
                lease_token TEXT,
                lease_until TEXT,
                error_code TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_strength_physiology_due
            ON strength_physiology(next_attempt_at);
            CREATE TABLE IF NOT EXISTS webpush_subscriptions (
                id TEXT PRIMARY KEY,
                subscription_json TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                notify_from TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS workout_push_deliveries (
                session_id TEXT NOT NULL,
                subscription_id TEXT NOT NULL,
                started_at TEXT NOT NULL,
                ended_at TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at TEXT,
                lease_token TEXT,
                lease_until TEXT,
                delivered_at TEXT,
                PRIMARY KEY(session_id, subscription_id)
            );
            CREATE TABLE IF NOT EXISTS observation_push_deliveries (
                insight_id INTEGER NOT NULL,
                subscription_id TEXT NOT NULL,
                slot TEXT NOT NULL,
                report_date TEXT NOT NULL,
                expires_at TEXT NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at TEXT,
                lease_token TEXT,
                lease_until TEXT,
                delivered_at TEXT,
                PRIMARY KEY(insight_id, subscription_id)
            );
            CREATE INDEX IF NOT EXISTS idx_observation_push_due
            ON observation_push_deliveries(next_attempt_at);

            DELETE FROM health_metrics
            WHERE id NOT IN (SELECT MAX(id) FROM health_metrics GROUP BY date);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_health_metrics_date
            ON health_metrics(date);

            CREATE INDEX IF NOT EXISTS idx_ai_insights_date_slot
            ON ai_insights(date, time_slot);

            CREATE INDEX IF NOT EXISTS idx_training_analysis_date
            ON training_analysis(date);

            CREATE INDEX IF NOT EXISTS idx_notification_events_date
            ON notification_events(event_date);
        """)

        # Migrate databases created by earlier AI-backed versions without
        # deleting their historical rows. New queries can then distinguish the
        # provider that actually produced each analysis.
        for table in ("ai_insights", "training_analysis"):
            columns = {
                row[1] for row in conn.execute(f"PRAGMA table_info({table})").fetchall()
            }
            if "provider" not in columns:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN provider TEXT")
            if "model" not in columns:
                conn.execute(f"ALTER TABLE {table} ADD COLUMN model TEXT")
        for table in ("ai_insights", "training_analysis"):
            columns = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
            for name in ("report_json", "input_hash", "input_json", "prompt_version"):
                if name not in columns:
                    conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} TEXT")
        from .strength_training import seed_catalog
        seed_catalog(conn)
        conn.commit()


HEALTH_FIELDS = (
    "steps", "distance_km", "sleep_hours", "sleep_quality", "hrv",
    "resting_hr", "calories_burned", "active_minutes",
)


def cache_health_metrics(metrics):
    """Upsert one metric dict or a list of metric dicts by date."""
    rows = metrics if isinstance(metrics, list) else [metrics]
    rows = [row for row in rows if row and row.get("date")]
    if not rows:
        return
    with get_db() as conn:
        for row in rows:
            values = [row.get(field, 0 if field != "sleep_quality" else "—") for field in HEALTH_FIELDS]
            conn.execute(
                """INSERT INTO health_metrics
                   (date, steps, distance_km, sleep_hours, sleep_quality, hrv,
                    resting_hr, calories_burned, active_minutes)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(date) DO UPDATE SET
                     steps=excluded.steps,
                     distance_km=excluded.distance_km,
                     sleep_hours=excluded.sleep_hours,
                     sleep_quality=excluded.sleep_quality,
                     hrv=excluded.hrv,
                     resting_hr=excluded.resting_hr,
                     calories_burned=excluded.calories_burned,
                     active_minutes=excluded.active_minutes,
                     created_at=datetime('now')""",
                [row["date"], *values],
            )
        conn.commit()


def get_cached_health_metrics(days=14):
    with get_db() as conn:
        rows = conn.execute(
            "SELECT * FROM health_metrics ORDER BY date DESC LIMIT ?",
            (max(1, min(int(days), 366)),),
        ).fetchall()
        return [dict(row) for row in rows]


def get_cached_health_today():
    from datetime import datetime

    today = datetime.now().strftime("%Y-%m-%d")
    with get_db() as conn:
        row = conn.execute(
            "SELECT * FROM health_metrics WHERE date = ?", (today,)
        ).fetchone()
        return dict(row) if row else None
