"""The training plan's own checks (tools/pine_program.py) and how a plan
revision reaches an existing database."""
import importlib.util
import json
import sqlite3
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[2] / "tools" / "pine_program.py"


class PineProgramTests(unittest.TestCase):
    def test_plan_passes_its_checks_and_matches_the_generator(self):
        if not TOOL.exists():
            self.skipTest("tools/ is not part of this checkout")
        spec = importlib.util.spec_from_file_location("pine_program", TOOL)
        tool = importlib.util.module_from_spec(spec); spec.loader.exec_module(tool)
        exercises = tool.load_exercises()
        catalog = {e["id"]: e for e in exercises}
        templates = tool.build(catalog)
        self.assertEqual(tool.check(templates, catalog), [])
        data = Path(__file__).resolve().parents[1] / "app" / "data"
        self.assertEqual(json.loads((data / "pine_program.json").read_text(encoding="utf-8")), templates)
        self.assertIn("flat-dumbbell-bench-press", {e["id"] for e in json.loads((data / "exercises.json").read_text(encoding="utf-8"))})


class PineRevisionSeedTests(unittest.TestCase):
    def setUp(self):
        from app import strength_training as st
        self.st = st
        self.conn = sqlite3.connect(":memory:")
        self.conn.executescript("CREATE TABLE strength_exercises (id TEXT PRIMARY KEY, document_json TEXT);"
                                "CREATE TABLE strength_templates (id TEXT PRIMARY KEY, document_json TEXT, version INTEGER);")

    def stored(self, tid):
        return self.conn.execute("SELECT document_json, version FROM strength_templates WHERE id=?", (tid,)).fetchone()

    def test_a_new_revision_replaces_pine_templates_once(self):
        self.conn.execute("INSERT INTO strength_templates VALUES ('pine-a-home', '{\"old\":true}', 3)")
        self.conn.execute("INSERT INTO strength_templates VALUES ('guided-upper-a', '{\"mine\":true}', 2)")
        self.st.seed_catalog(self.conn)
        doc, version = self.stored("pine-a-home")
        self.assertEqual(json.loads(doc)["exercises"][0]["exercise_id"], "flat-dumbbell-bench-press")
        self.assertEqual(version, 4)
        self.assertEqual(self.stored("guided-upper-a"), ('{"mine":true}', 2))
        # Later edits in the app survive restarts of the same revision.
        self.conn.execute("UPDATE strength_templates SET document_json='{\"edited\":true}', version=5 WHERE id='pine-a-home'")
        self.st.seed_catalog(self.conn)
        self.assertEqual(self.stored("pine-a-home"), ('{"edited":true}', 5))

    def test_unchanged_templates_keep_their_version(self):
        self.st.seed_catalog(self.conn)
        self.conn.execute("DELETE FROM catalog_revisions")
        self.st.seed_catalog(self.conn)
        self.assertEqual(self.stored("pine-b-home")[1], 1)
