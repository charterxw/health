"""The fields of GET /api/home that the iPhone app decodes as types.

Mirrors ios/Shared/NativeHome.swift. The app's core checks decode the synthetic
sample in docs/contracts/home-summary.json with that model; this test keeps the
server's current output and that sample in the same shape.
"""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from app import database
from app.home_dashboard import summary

SAMPLE = Path(__file__).resolve().parents[2] / 'docs' / 'contracts' / 'home-summary.json'
NUMBER = (int, float)
OPTIONAL_NUMBER = (int, float, type(None))
OPTIONAL_TEXT = (str, type(None))
DAY = {'date': str, 'short': str, 'activity': OPTIONAL_NUMBER, 'sets': int, 'target': int, 'posture': bool,
       'posture_planned': bool, 'strength_planned': bool, 'strength_optional': bool}
REQUIRED = {
    'date': str, 'timezone': str, 'next_effective': str,
    'days': [DAY],
    'goals': {'dailyActivity': NUMBER, 'weeklyActivity': NUMBER, 'weeklyStrength': int, 'weeklyPosture': int},
    'step_goal': {'target': NUMBER},
    'recovery': {'score': OPTIONAL_NUMBER, 'label': OPTIONAL_TEXT},
    # Every feelings field is optional: a day without feelings is an empty object.
    'feedback': dict,
}
FEEDBACK = {'energy': OPTIONAL_TEXT, 'fatigue': OPTIONAL_TEXT, 'soreness': (list, type(None)), 'stress': OPTIONAL_TEXT, 'note': OPTIONAL_TEXT}


def problems(value, shape, path='home'):
    if isinstance(shape, dict):
        if not isinstance(value, dict):
            return [f'{path} is not an object']
        found = []
        for key, inner in shape.items():
            if key not in value:
                found.append(f'{path}.{key} is missing')
            else:
                found += problems(value[key], inner, f'{path}.{key}')
        return found
    if isinstance(shape, list):
        if not isinstance(value, list):
            return [f'{path} is not a list']
        return [p for i, item in enumerate(value) for p in problems(item, shape[0], f'{path}[{i}]')]
    kinds = shape if isinstance(shape, tuple) else (shape,)
    # JSON booleans are not numbers for the app.
    if isinstance(value, bool) and bool not in kinds:
        return [f'{path} is a boolean']
    return [] if isinstance(value, kinds) else [f'{path} is {type(value).__name__}']


class HomeContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_path = database.DB_PATH
        database.DB_PATH = os.path.join(self.tmp.name, 'test.db')
        database.init_db()
        self.env = patch.dict(os.environ, {'JWT_SECRET': 'home-contract-test-secret-with-32-chars'})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        database.DB_PATH = self.old_path
        self.tmp.cleanup()

    def check(self, document):
        found = problems(document, REQUIRED)
        found += [p for key, kinds in FEEDBACK.items() if key in document.get('feedback', {})
                  for p in problems(document['feedback'][key], kinds, 'home.feedback.' + key)]
        self.assertEqual(found, [])
        self.assertEqual(len(document['days']), 7)

    def test_current_summary_has_the_fields_the_app_decodes(self):
        self.check(summary())

    def test_feelings_keep_the_decoded_types(self):
        from fastapi.testclient import TestClient
        from app.home_dashboard import router
        from fastapi import FastAPI
        app = FastAPI(); app.include_router(router)
        with TestClient(app) as client:
            document = client.put('/api/home/feedback', json={'energy': '一般', 'soreness': ['肩'], 'stress': '低', 'note': '好'}).json()
        self.check(document)

    def test_committed_sample_matches_the_contract(self):
        self.check(json.loads(SAMPLE.read_text()))


if __name__ == '__main__':
    unittest.main()
