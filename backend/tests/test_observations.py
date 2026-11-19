import asyncio
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta
from unittest.mock import patch

from app import database, observations, openai_service, scheduler


class ObservationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.old_path = database.DB_PATH
        database.DB_PATH = os.path.join(self.temp.name, "test.db")
        database.init_db()

    def tearDown(self):
        database.DB_PATH = self.old_path
        self.temp.cleanup()

    def test_zero_missing_naps_and_duplicates_do_not_pollute_baselines(self):
        rows = observations.sleep_rows([
            {"date": "2026-11-02", "minutes_asleep": 420, "hrv": 0, "total_awake_mins": 0, "skin_temperature_delta_c": 0},
            {"date": "2026-11-02", "minutes_asleep": 480, "is_nap": True},
            {"date": "2026-11-01", "minutes_asleep": 0},
            {"date": "2026-11-02", "minutes_asleep": 20},
        ])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["minutes_asleep"], 420)
        self.assertIsNone(rows[0]["hrv"])
        self.assertEqual(rows[0]["total_awake_mins"], 0)
        self.assertEqual(rows[0]["skin_temperature_delta_c"], 0)

    def test_sleep_window_decomposition_uses_paired_nights(self):
        rows = observations.sleep_rows([
            {"date": "2026-11-03", "minutes_asleep": 360, "minutes_in_bed": 420},
            {"date": "2026-11-02", "minutes_asleep": 480, "minutes_in_bed": 500},
            {"date": "2026-11-01", "minutes_asleep": 540},
        ])
        split = observations.daily_context(rows, "2026-11-03")["sleep_window_decomposition"]
        self.assertEqual(split["n"], 1)
        self.assertEqual(split["sleep_delta_minutes"], -120)
        self.assertEqual(split["window_delta_minutes"], -80)
        self.assertEqual(split["awake_within_window_delta_minutes"], 40)

    def test_weekly_excludes_today_and_leaves_missing_nights_as_gaps(self):
        rows = observations.sleep_rows([
            {"date": "2026-11-03", "minutes_asleep": 360},
            {"date": "2026-11-02", "minutes_asleep": 420},
            {"date": "2026-10-31", "minutes_asleep": 480},
            {"date": "2026-10-25", "minutes_asleep": 500},
        ])
        context = observations.weekly_context(rows, "2026-11-02", [])
        self.assertEqual(context["valid_nights"], 2)
        self.assertEqual(context["week_stats"]["minutes_asleep"]["mean"], 450)
        self.assertEqual(context["baseline_stats"]["minutes_asleep"]["n"], 1)
        self.assertEqual(len(context["calendar"]), 7)
        self.assertIsNone(context["calendar"][0]["minutes_asleep"])
        self.assertNotIn("2026-11-03", [r["date"] for r in context["calendar"]])

    def test_same_input_is_cached_and_corrected_input_regenerates(self):
        report = {"status": "finding", "summary": "", "findings": [{
            "headline": "睡眠窗口缩短", "body": "清醒时间同时增加。",
            "evidence": ["2026-11-03：主睡眠360分钟"], "confidence": "medium"}], "limitations": ""}
        context = {"period": {"start": "2026-11-03", "end": "2026-11-03"}, "minutes": 360}
        with patch.object(openai_service, "_call_openai", return_value=json.dumps(report)) as call:
            first = observations._save_report("sleep", "2026-11-03", "Deep Sleep Analysis", context, notify=False)
            second = observations._save_report("sleep", "2026-11-03", "Deep Sleep Analysis", context, notify=False)
            self.assertEqual(first["content"], second["content"])
            self.assertNotIn("input_json", second)
            self.assertEqual(call.call_count, 1)
            observations._save_report("sleep", "2026-11-03", "Deep Sleep Analysis", dict(context, minutes=380), notify=False)
            self.assertEqual(call.call_count, 2)
        with database.get_db() as conn:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM ai_insights").fetchone()[0], 1)

    def test_empty_zero_input_never_calls_model(self):
        with patch.object(openai_service, "_call_openai") as call, patch(
            "app.workout_data.get_training_workouts", return_value=[]
        ):
            with self.assertRaises(openai_service.AIServiceError):
                observations.generate_evening_observation(
                    {"date": datetime.now().strftime("%Y-%m-%d"), "hrv": 0, "steps": 0}, notify=False,
                )
        call.assert_not_called()

    def test_evening_uses_same_day_health_morning_sleep_and_local_strength(self):
        today = datetime.now().strftime("%Y-%m-%d")
        yesterday = (datetime.now() - timedelta(days=1)).strftime("%Y-%m-%d")
        night = {"date": today, "minutes_asleep": 420}
        morning = {"status": "unchanged", "summary": "睡眠时长接近平时。", "findings": [], "limitations": ""}
        with patch.object(openai_service, "_require_ai_configured"), patch.object(
            openai_service, "_call_openai", return_value=json.dumps(morning)
        ), patch.object(observations, "load_sleep", return_value=observations.sleep_rows([night])):
            self.assertEqual(observations.generate_sleep_observation(notify=False)["time_slot"], "morning")

        workout = {"datestr": today, "source": "local", "exercises": []}
        archive = {"datestr": today, "source": "xunji", "exercises": []}
        previous = {"datestr": yesterday, "source": "xunji", "exercises": []}
        with patch("app.workout_data.get_training_workouts", return_value=[workout, archive, previous]), patch(
            "app.training_observations.training_context", return_value=None,
        ) as compare, patch.object(observations, "_save_report") as save:
            observations.generate_evening_observation({"date": today, "steps": 6020}, notify=False)
        compare.assert_called_once_with([workout, previous], [], working_only=True)
        slot, _, _, context = save.call_args.args
        self.assertEqual(slot, "evening")
        self.assertEqual(context["today_activity_and_health"]["steps"], 6020)
        self.assertEqual(context["sleep_today"]["main_sleep"]["minutes_asleep"], 420)
        self.assertEqual(context["sleep_today"]["morning_report"]["summary"], morning["summary"])
        self.assertEqual(context["today_strength"], [workout])

    def test_evening_retries_invalid_model_report_and_passes_snapshot_time(self):
        day = "2026-11-09"
        context = {"period": {"start": day, "end": day}}
        valid = {"status": "unchanged", "summary": "没有超出近期波动。", "findings": [], "limitations": ""}
        with patch.object(openai_service, "_call_openai", side_effect=["{}", json.dumps(valid)]) as model:
            report = observations._save_report("evening", day, observations.EVENING_TITLE, context,
                                               notify=False, as_of="21:00")
        self.assertEqual(model.call_count, 2)
        self.assertIn('"activity_snapshot_local_time": "21:00"', model.call_args.args[0])
        self.assertEqual(report["report"]["as_of"], "21:00")
        self.assertEqual(report["report"]["version"], observations.DAILY_VERSION)

    def test_evening_scheduler_retries_until_report_exists(self):
        local = datetime(2026, 11, 9, 21, 0, tzinfo=scheduler.scheduler.timezone)
        with patch.object(scheduler, "is_ai_configured", return_value=True), patch.object(
            scheduler, "generate_evening_insight", side_effect=openai_service.AIServiceError("retry")
        ) as generate:
            scheduler.run_evening_pipeline(local.replace(hour=20))
            generate.assert_not_called()
            scheduler.run_evening_pipeline(local)
            scheduler.run_evening_pipeline(local.replace(minute=10))
            self.assertEqual(generate.call_count, 2)
            openai_service._upsert_insight("2026-11-09", "evening", observations.EVENING_TITLE, "已完成", "observation")
            scheduler.run_evening_pipeline(local.replace(minute=20))
            self.assertEqual(generate.call_count, 2)

    def test_evening_keeps_fresh_fields_when_one_health_request_fails(self):
        async def read(field, date):
            if field == "hrv":
                raise TimeoutError
            return {field: 6400 if field == "steps" else 0}

        with patch("app.google_health.get_today_metric", side_effect=read), patch.object(
            openai_service, "get_cached_health_today", return_value={"date": "2026-11-09", "hrv": 25},
        ):
            result = asyncio.run(openai_service._observation_day_metrics("2026-11-09", ("steps", "hrv", "resting_hr")))
        self.assertEqual(result, {"date": "2026-11-09", "_cached_fields": ["hrv"],
                                  "steps": 6400.0, "hrv": 25.0, "resting_hr": None})

    def test_rejects_daily_essays_and_status_mismatch(self):
        report = {"status": "finding", "summary": "", "findings": [{
            "headline": "x", "body": "x" * 200, "evidence": ["sample"], "confidence": "low"}], "limitations": ""}
        with self.assertRaises(ValueError):
            observations.validate_report(report)
        with self.assertRaises(ValueError):
            observations.validate_report(dict(report, status="unchanged"))

    def test_local_sleep_times_handle_midnight_without_inventing_timezone(self):
        before = observations.local_minutes("2026-11-02T04:30:00Z", "-18000s")
        after = observations.local_minutes("2026-11-03T05:30:00Z", "-18000s")
        self.assertEqual(after - before, 60)
        self.assertIsNone(observations.local_minutes("2026-11-02T04:30:00Z", None))


if __name__ == "__main__":
    unittest.main()
