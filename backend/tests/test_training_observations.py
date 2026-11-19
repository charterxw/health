import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app import database, openai_service, xunji_service
from app import training_observations as training
from app.routes.insights import get_training_analysis
from app.routes.workouts import get_exercises, get_training_archive, get_training_for_date, get_workout_archive, sync_training
import asyncio


def session(date, name="卧推", weight="45", reps=(8, 8), unit="lbs", **kwargs):
    return {"datestr": date, "movements": [{"name": name, **kwargs, "sets": [
        {"weight": weight, "unit": unit, "reps": str(r)} for r in reps]}]}


class TrainingTests(unittest.TestCase):
    def test_workout_archive_reads_the_frozen_google_health_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp, "fitness.db")
            frozen = [{"date": "2026-11-08", "name": "Walk", "duration_minutes": 20}]
            Path(tmp, "google_exercise_archive.json").write_text(json.dumps(frozen))
            old_training = [session("2022-05-15")]
            with patch("app.routes.workouts.get_db_path", return_value=str(db_path)), \
                 patch("app.routes.workouts.get_all_cached_workouts", return_value=old_training):
                self.assertEqual(get_exercises(), frozen)
                self.assertEqual(get_workout_archive(), {"exercises": frozen, "training": old_training})

    def test_legacy_archive_can_open_older_dates_without_changing_the_database(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "archive.db")
            with sqlite3.connect(path) as conn:
                conn.execute("CREATE TABLE daily_trains (datestr TEXT, full_json TEXT)")
                conn.execute("INSERT INTO daily_trains VALUES (?, ?)",
                             ("2022-05-15", json.dumps([session("2022-05-15")])))
            before = path.read_bytes()
            with patch.object(xunji_service, "DB_PATH", str(path)), patch("app.routes.workouts.get_strength_workouts", return_value=[]):
                history = get_training_archive(None)
                self.assertEqual(history[0]["source"], "archive")
                self.assertEqual(asyncio.run(get_training_for_date("2022-05-15")), history)
                self.assertEqual(asyncio.run(get_training_for_date("2022-05-16")), [])
                self.assertEqual(asyncio.run(sync_training()), {"synced": 0})
            self.assertEqual(path.read_bytes(), before)

    def test_includes_matching_exercises_beyond_fourteen_days_and_marks_gap(self):
        context = training.training_context([session("2026-11-02", weight="20"),
                                             session("2026-09-11", weight="25")], [])
        match = context["recorded_peak_comparisons"][0]
        self.assertEqual(match["gap_days"], 52)
        self.assertTrue(match["identical_reps_and_set_count"])
        self.assertEqual(match["recorded_weight_delta"], -5)

    def test_different_units_exercises_and_load_modes_are_not_compared(self):
        workouts = [session("2026-11-02"), session("2026-11-01", unit="kg"),
                    session("2026-10-31", name="上斜卧推"), session("2026-10-30", exetype="help")]
        context = training.training_context(workouts, [])
        self.assertEqual(context["recorded_peak_comparisons"], [])
        self.assertEqual(context["exact_same_weight_comparisons"], [])

    def test_assistance_is_not_treated_as_external_load_or_strength_peak(self):
        context = training.training_context([
            session("2026-11-02", name="双杠臂屈伸", weight="60", exetype="help"),
            session("2026-09-11", name="双杠臂屈伸", weight="40", exetype="help")], [])
        self.assertEqual(context["recorded_peak_comparisons"], [])
        self.assertEqual(context["latest_sessions"][0]["movements"][0]["sets"][0]["mode"], "assistance")

    def test_recovery_is_date_paired_and_zero_is_missing(self):
        context = training.training_context([session("2026-11-02")], [
            {"date": "2026-11-01", "hrv": 88}, {"date": "2026-11-02", "hrv": 0},
            {"date": "2026-11-03", "hrv": 24, "sleep_hours": 6}])
        pair = context["recovery_pairs"][0]
        self.assertIsNone(pair["training_day"]["hrv"])
        self.assertEqual(pair["next_wake_day"]["date"], "2026-11-03")
        self.assertEqual(pair["next_wake_day"]["hrv"], 24)

    def test_skips_unfinished_sets_and_keeps_order_without_guessing_warmups(self):
        workout = session("2026-11-02", reps=(10, 8, 6))
        workout["movements"][0]["sets"][1]["done"] = False
        movement = training.normalized_workouts([workout, workout])[0]["movements"][0]
        self.assertEqual(movement["load_groups"][0]["reps"], [10, 6])
        self.assertEqual(movement["load_groups"][0]["set_indices"], [1, 3])
        self.assertIsNone(movement["sets"][0]["warmup"])

    def test_reuses_valid_report_and_preserves_history_on_invalid_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            old_path = database.DB_PATH
            database.DB_PATH = os.path.join(tmp, "fitness.db")
            try:
                database.init_db()
                report = {"status": "finding", "summary": "", "findings": [{
                    "headline": "选用负重变轻", "body": "两次记录相隔52天，不能认定力量持续下降。",
                    "evidence": ["11/2与9/11：同动作、同次数"], "confidence": "medium"}], "limitations": ""}
                with patch.object(openai_service, "_require_ai_configured"), patch.object(
                    xunji_service, "get_all_cached_workouts", return_value=[session("2026-11-02")]
                ), patch.object(openai_service, "_get_recent_metrics", return_value=[]), patch.object(
                    openai_service, "_call_openai", return_value=json.dumps(report)
                ) as model:
                    first = training.generate_training_observation(notify=False)
                    second = training.generate_training_observation(notify=False)
                    self.assertEqual(first["summary"], second["summary"])
                    self.assertEqual(model.call_count, 1)
                    self.assertNotIn("input_json", second)
                    model.return_value = "not valid json"
                    with self.assertRaises(openai_service.AIServiceError):
                        training.generate_training_observation(force=True, notify=False)
                    model.return_value = json.dumps(report)
                    newer = training.generate_training_observation(force=True, notify=False)
                with database.get_db() as conn:
                    self.assertEqual(conn.execute("SELECT COUNT(*) FROM training_analysis").fetchone()[0], 2)
                self.assertEqual([entry["id"] for entry in get_training_analysis(history=True)],
                                 [newer["id"], first["id"]])
            finally:
                database.DB_PATH = old_path


if __name__ == "__main__":
    unittest.main()
