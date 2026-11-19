import random
from datetime import datetime, timedelta
from .database import get_db


WORKOUT_TYPES = ["Running", "Lifting", "Cycling", "Swimming", "HIIT", "Yoga"]
INTENSITIES = ["Low", "Moderate", "High", "Very High"]
SLEEP_QUALITIES = ["Poor", "Fair", "Good", "Excellent"]


def generate_health_metrics(date: str) -> dict:
    steps = random.randint(4000, 15000)
    return {
        "date": date,
        "steps": steps,
        "distance_km": round(steps * 0.0008 + random.uniform(-0.5, 0.5), 1),
        "sleep_hours": round(random.uniform(5.5, 9.0), 1),
        "sleep_quality": random.choice(SLEEP_QUALITIES),
        "hrv": random.randint(25, 85),
        "resting_hr": random.randint(55, 75),
        "calories_burned": random.randint(1800, 3200),
        "active_minutes": random.randint(15, 120),
    }


def generate_workout(date: str) -> dict:
    workout_type = random.choice(WORKOUT_TYPES)
    intensity = random.choice(INTENSITIES)
    duration = random.randint(20, 90)

    cal_base = {"Low": 4, "Moderate": 7, "High": 10, "Very High": 13}
    calories = duration * cal_base[intensity] + random.randint(-50, 50)

    return {
        "date": date,
        "type": workout_type,
        "duration_minutes": duration,
        "intensity": intensity,
        "calories_burned": max(calories, 50),
        "notes": f"{workout_type} session - {intensity} intensity",
    }


def seed_mock_data(days: int = 14):
    """Seed the database with mock data for the last N days."""
    today = datetime.now()

    with get_db() as conn:
        # Check if data already exists
        cursor = conn.execute("SELECT COUNT(*) FROM health_metrics")
        if cursor.fetchone()[0] > 0:
            return

        for i in range(days, -1, -1):
            date = (today - timedelta(days=i)).strftime("%Y-%m-%d")

            # Health metrics (one per day)
            metrics = generate_health_metrics(date)
            conn.execute(
                """INSERT INTO health_metrics
                   (date, steps, distance_km, sleep_hours, sleep_quality, hrv, resting_hr, calories_burned, active_minutes)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    metrics["date"],
                    metrics["steps"],
                    metrics["distance_km"],
                    metrics["sleep_hours"],
                    metrics["sleep_quality"],
                    metrics["hrv"],
                    metrics["resting_hr"],
                    metrics["calories_burned"],
                    metrics["active_minutes"],
                ),
            )


        conn.commit()
