import asyncio
import os
import tempfile
import unittest
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

from app import database
from app import google_health
from app import openai_service
from app import chatgpt_auth
from app import notifications
from app.main import app
from app.routes import health


class DatabaseTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        database.DB_PATH = os.path.join(self.tmpdir.name, "fitness.db")
        database.init_db()

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_health_cache_upserts_by_date(self):
        today = datetime.now().strftime("%Y-%m-%d")
        database.cache_health_metrics({"date": today, "steps": 100})
        database.cache_health_metrics({"date": today, "steps": 250})
        row = database.get_cached_health_today()
        self.assertEqual(row["steps"], 250)
        with database.get_db() as conn:
            count = conn.execute(
                "SELECT COUNT(*) FROM health_metrics WHERE date = ?", (today,)
            ).fetchone()[0]
        self.assertEqual(count, 1)

    def test_analysis_tables_track_the_generating_provider(self):
        with database.get_db() as conn:
            insight_columns = {
                row[1] for row in conn.execute("PRAGMA table_info(ai_insights)")
            }
            training_columns = {
                row[1] for row in conn.execute("PRAGMA table_info(training_analysis)")
            }
        self.assertTrue({"provider", "model"}.issubset(insight_columns))
        self.assertTrue({"provider", "model"}.issubset(training_columns))


class GoogleHealthTests(unittest.TestCase):
    def test_dashboard_today_metric_only_requests_its_own_source(self):
        now = datetime.now()
        date = now.date().isoformat()
        point = {"civilStartTime": {"date": {"year": now.year, "month": now.month, "day": now.day}},
                 "steps": {"countSum": "6240"}}
        with patch.object(health, "is_authenticated", return_value=True), \
             patch.object(google_health, "_daily_rollup", new_callable=AsyncMock, return_value=[point]) as fetch, \
             patch.object(health, "gh_today", new_callable=AsyncMock) as full, \
             patch.object(health, "cache_health_metrics") as cache:
            result = asyncio.run(health.get_today_metrics("steps"))
            self.assertEqual(result, {"date": date, "steps": 6240})
            fetch.assert_awaited_once_with("steps", 1)
            full.assert_not_called()
            cache.assert_not_called()

    def test_one_day_range_does_not_include_yesterday(self):
        start, end = google_health._date_range(1)
        self.assertEqual(start, end)

    def test_sleep_is_assigned_to_local_wake_date(self):
        point = {
            "sleep": {
                "interval": {
                    "startTime": "2026-10-10T03:00:00Z",
                    "endTime": "2026-10-10T11:00:00Z",
                    "civilEndTime": {
                        "date": {"year": 2026, "month": 10, "day": 10}
                    },
                },
                "summary": {"minutesAsleep": 450},
                "metadata": {"nap": False},
            }
        }
        date, hours, is_nap = google_health._sleep_date_and_hours(point)
        self.assertEqual(date, "2026-10-10")
        self.assertEqual(hours, 7.5)
        self.assertFalse(is_nap)

    def test_sleep_recovery_metrics_are_joined_by_date(self):
        date = {"year": 2026, "month": 10, "day": 11}
        result = google_health._sleep_recovery_by_date(
            [{"dailyOxygenSaturation": {
                "date": date,
                "averagePercentage": 97.2,
                "lowerBoundPercentage": 94.4,
                "upperBoundPercentage": 100,
            }}],
            [{"dailyRespiratoryRate": {
                "date": date,
                "breathsPerMinute": 15.4,
            }}],
            [{"dailySleepTemperatureDerivations": {
                "date": date,
                "nightlyTemperatureCelsius": 32.87,
                "baselineTemperatureCelsius": 33.08,
            }}],
        )
        self.assertEqual(result["2026-10-11"]["spo2_average"], 97.2)
        self.assertEqual(result["2026-10-11"]["respiratory_rate"], 15.4)
        self.assertEqual(result["2026-10-11"]["skin_temperature_delta_c"], -0.21)

    def test_list_filters_use_supported_fields_and_pagination(self):
        fake_get = AsyncMock(return_value={"dataPoints": []})
        with patch.object(google_health, "_api_get", fake_get):
            asyncio.run(google_health._list_sleep(2))
            sleep_params = fake_get.await_args.kwargs["params"]
            self.assertIn("sleep.interval.civil_end_time", sleep_params["filter"])
            self.assertEqual(sleep_params["pageSize"], 25)
            self.assertTrue(fake_get.await_args.kwargs["paginate"])

            asyncio.run(google_health._list_exercises(2))
            exercise_params = fake_get.await_args.kwargs["params"]
            self.assertIn(
                "exercise.interval.civil_start_time", exercise_params["filter"]
            )

            asyncio.run(google_health._list_daily("daily-resting-heart-rate", 2))
            daily_params = fake_get.await_args.kwargs["params"]
            self.assertIn("daily_resting_heart_rate.date", daily_params["filter"])


class OpenAITests(unittest.TestCase):
    def test_missing_chatgpt_connection_is_explicit_and_never_calls_network(self):
        with tempfile.TemporaryDirectory() as tmpdir, patch.dict(
            os.environ,
            {"CHATGPT_CREDENTIALS_FILE": os.path.join(tmpdir, "missing.json")},
            clear=False,
        ):
            self.assertFalse(openai_service.is_ai_configured())
            with self.assertRaisesRegex(
                openai_service.AIServiceError, "ChatGPT is not connected"
            ):
                openai_service._call_openai("test")

    def test_morning_analysis_waits_for_main_sleep(self):
        with patch.object(openai_service, "_require_ai_configured"), patch(
            "app.observations.load_sleep", return_value=[]
        ), patch.object(openai_service, "_call_openai") as call_ai:
            with self.assertRaises(openai_service.AIServiceError) as raised:
                openai_service.generate_morning_insight()

        self.assertEqual(raised.exception.code, "health_data_not_fresh")
        self.assertEqual(raised.exception.status_code, 409)
        call_ai.assert_not_called()

    def test_sleep_trend_context_uses_personal_baseline(self):
        current = {
            "date": "2026-10-11",
            "minutes_asleep": 420,
            "sleep_efficiency_percent": 90,
            "total_deep_mins": 84,
            "total_rem_mins": 105,
            "total_awake_mins": 35,
            "hrv": 40,
            "resting_hr": 58,
        }
        previous = [
            {
                "date": "2026-10-10",
                "minutes_asleep": 480,
                "sleep_efficiency_percent": 95,
                "total_deep_mins": 96,
                "total_rem_mins": 120,
                "total_awake_mins": 20,
                "hrv": 50,
                "resting_hr": 55,
            },
            {
                "date": "2026-10-09",
                "minutes_asleep": 460,
                "sleep_efficiency_percent": 93,
                "total_deep_mins": 92,
                "total_rem_mins": 115,
                "total_awake_mins": 24,
                "hrv": 48,
                "resting_hr": 56,
            },
        ]
        context = openai_service._sleep_trend_context(current, previous)
        self.assertIn("历史不足，只能视为短期迹象", context)
        self.assertIn("HRV：昨晚 40ms", context)
        self.assertIn("差值 -9.0ms", context)


class ChatGPTAuthTests(unittest.TestCase):
    def test_expired_access_token_is_refreshed_and_rotated_atomically(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "chatgpt-oauth.json"
            path.write_text(
                json.dumps(
                    {
                        "client_id": "oaiapp_test",
                        "access_token": "old-access",
                        "refresh_token": "old-refresh",
                        "expires_in": 3600,
                        "saved_at": (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat(),
                        "scopes": ["chatgpt.tokens.use.direct", "offline_access"],
                    }
                ),
                encoding="utf-8",
            )
            response = Mock(status_code=200)
            response.json.return_value = {
                "access_token": "new-access",
                "refresh_token": "new-refresh",
                "expires_in": 3600,
                "scope": "chatgpt.tokens.use.direct offline_access",
            }
            with patch.dict(
                os.environ,
                {"CHATGPT_CREDENTIALS_FILE": str(path)},
                clear=False,
            ), patch.object(chatgpt_auth.httpx, "post", return_value=response):
                self.assertEqual(chatgpt_auth.get_access_token(), "new-access")

            saved = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(saved["refresh_token"], "new-refresh")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)


class NotificationTests(unittest.TestCase):
    def test_unconfigured_notifications_are_a_safe_noop(self):
        with patch.dict(os.environ, {"TELEGRAM_NOTIFICATIONS_ENABLED": "true"}, clear=False):
            os.environ.pop("TELEGRAM_BOT_TOKEN", None)
            os.environ.pop("TELEGRAM_CHAT_ID", None)
            with patch.object(notifications, "_bot_token", return_value=""), patch.object(
                notifications, "_chat_id", return_value=""
            ):
                self.assertFalse(notifications.send_telegram_message("Test", "Body"))


class RouteTests(unittest.TestCase):
    def test_required_routes_exist(self):
        paths = {route.path for route in app.routes}
        self.assertIn("/api/workouts/recent", paths)
        self.assertIn("/api/insights/training/generate", paths)
        self.assertIn("/api/insights/sleep/generate", paths)
        self.assertIn("/api/auth/logout", paths)
        self.assertIn("/api/integrations/status", paths)
        self.assertIn("/api/integrations/telegram/test", paths)


if __name__ == "__main__":
    unittest.main()
