import os
import tempfile
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from app import body_log, database, security
from app.main import app


class BodyLogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.old_path = database.DB_PATH
        database.DB_PATH = os.path.join(self.tmp.name, 'test.db')
        database.init_db()
        self.env = patch.dict(os.environ, {'JWT_SECRET': 'body-log-test-secret-with-32-plus-chars',
                                           'DASHBOARD_USER': 'test', 'DASHBOARD_PASS': 'test-password'})
        self.env.start()
        self.client = TestClient(app)
        security.init_security()
        token, _ = security.issue_session('test')
        self.client.cookies.set('dashboard_session', token)

    def tearDown(self):
        self.client.close()
        self.env.stop()
        database.DB_PATH = self.old_path
        self.tmp.cleanup()

    def test_measurements_are_idempotent_by_id_and_deletable(self):
        self.assertEqual(self.client.get('/api/body').json(), {'measurements': [], 'protein': {}})
        body = {'kind': 'waist', 'date': '2026-11-20', 'cm': 80.46}
        for _ in range(2):
            saved = self.client.put('/api/body/measurements/a1', json=body)
            self.assertEqual(saved.status_code, 200, saved.text)
        self.assertEqual(saved.json()['measurements'], [{'id': 'a1', 'kind': 'waist', 'date': '2026-11-20', 'cm': 80.5}])
        moved = self.client.put('/api/body/measurements/a1', json={**body, 'cm': 79.0}).json()
        self.assertEqual(moved['measurements'][0]['cm'], 79.0)
        self.assertEqual(self.client.delete('/api/body/measurements/a1').json()['measurements'], [])
        self.assertEqual(self.client.delete('/api/body/measurements/missing').status_code, 200)

    def test_measurement_validation(self):
        cases = [{'kind': 'neck', 'date': '2026-11-20', 'cm': 40}, {'kind': 'waist', 'date': '2026-13-01', 'cm': 80},
                 {'kind': 'waist', 'date': '2026-11-20', 'cm': 5}, {'kind': 'waist', 'date': '2026-11-20', 'cm': 80, 'x': 1}]
        for case in cases:
            self.assertEqual(self.client.put('/api/body/measurements/b1', json=case).status_code, 422, case)

    def test_protein_is_a_daily_total_and_zero_removes_it(self):
        self.assertEqual(self.client.put('/api/body/protein/2026-11-20', json={'grams': 95}).json()['protein'], {'2026-11-20': 95.0})
        self.assertEqual(self.client.put('/api/body/protein/2026-11-20', json={'grams': 120}).json()['protein'], {'2026-11-20': 120.0})
        self.assertEqual(self.client.put('/api/body/protein/2026-11-20', json={'grams': 0}).json()['protein'], {})
        self.assertEqual(self.client.put('/api/body/protein/not-a-day', json={'grams': 10}).status_code, 422)
        self.assertEqual(self.client.put('/api/body/protein/2026-11-20', json={'grams': -1}).status_code, 422)

    def test_weekly_summary_compares_with_a_reading_four_weeks_earlier(self):
        for entry_id, day, cm in [('w0', '2026-10-20', 82.0), ('w1', '2026-11-10', 81.5), ('w2', '2026-11-19', 81.0)]:
            self.client.put('/api/body/measurements/' + entry_id, json={'kind': 'waist', 'date': day, 'cm': cm})
        self.client.put('/api/body/measurements/s1', json={'kind': 'shoulder', 'date': '2026-11-18', 'cm': 120})
        self.client.put('/api/body/protein/2026-11-18', json={'grams': 110})
        self.client.put('/api/body/protein/2026-11-01', json={'grams': 90})
        summary = body_log.weekly_summary('2026-11-15', '2026-11-21')
        self.assertEqual(summary['girths_cm']['waist'], {'date': '2026-11-19', 'cm': 81.0, 'change_cm': -1.0, 'compared_with': '2026-10-20'})
        self.assertIsNone(summary['girths_cm']['shoulder']['change_cm'])
        self.assertNotIn('arm', summary['girths_cm'])
        self.assertEqual(summary['protein_logged_days'], 1)
        self.assertEqual(summary['protein_grams_by_day'], {'2026-11-18': 110.0})

    def test_feelings_keep_sore_areas_stress_and_note(self):
        saved = self.client.put('/api/home/feedback', json={'energy': '一般', 'soreness': ['肩', '胸', '肩'], 'stress': '高', 'note': '  昨晚没睡好  '})
        self.assertEqual(saved.status_code, 200, saved.text)
        feeling = saved.json()['feedback']
        self.assertEqual(feeling['soreness'], ['胸', '肩'])
        self.assertEqual(feeling['stress'], '高')
        self.assertEqual(feeling['note'], '昨晚没睡好')
        cleared = self.client.put('/api/home/feedback', json={'soreness': [], 'note': ''}).json()['feedback']
        self.assertEqual(cleared['soreness'], [])
        self.assertIsNone(cleared['note'])
        self.assertEqual(cleared['energy'], '一般')
        self.assertEqual(self.client.put('/api/home/feedback', json={'soreness': ['脚']}).status_code, 422)
        self.assertEqual(self.client.put('/api/home/feedback', json={'note': 'x' * 201}).status_code, 422)

    def test_home_names_the_sessions_outside_the_round(self):
        extras = self.client.get('/api/home').json()['extras']
        self.assertEqual(extras['posture']['template_id'], 'posture-daily')
        self.assertEqual(extras['optional']['template_id'], 'pine-sat-optional')
        self.assertTrue(extras['optional']['weekend_only'])
        self.assertTrue(extras['optional']['focus'])


if __name__ == '__main__':
    unittest.main()
