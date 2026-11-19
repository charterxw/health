import unittest
from datetime import date, timedelta

from app.home_dashboard import readiness


def history(days=28, hrv=(28, 32), rhr=(60, 62), sleep=7.5):
    start = date(2026, 11, 19)
    return [{'date': (start - timedelta(days=i)).isoformat(), 'hrv': hrv[i % 2], 'resting_hr': rhr[i % 2], 'sleep_hours': sleep}
            for i in range(1, days + 1)]


def today(**values):
    return {'date': '2026-11-19', 'hrv': 30, 'resting_hr': 61, 'sleep_hours': 7.5, **values}


class ReadinessTests(unittest.TestCase):
    def score(self, day, rows=None):
        rows = history() if rows is None else rows
        return readiness(day, [day, *rows])

    def test_usual_night_is_within_normal_range(self):
        result = self.score(today())
        self.assertEqual(result['label'], '平稳')
        self.assertEqual(result['version'], 'personal-v2')
        self.assertLessEqual(result['hrv_range'][0], 30)
        self.assertGreaterEqual(result['hrv_range'][1], 30)

    def test_strong_signals_read_as_ample(self):
        rows = history()
        rows[:6] = [{**r, 'hrv': 36, 'resting_hr': 57, 'sleep_hours': 8.3} for r in rows[:6]]
        self.assertEqual(self.score(today(hrv=37, resting_hr=56, sleep_hours=8.4), rows)['label'], '充分')

    def test_weak_signals_read_as_low(self):
        rows = history()
        rows[:6] = [{**r, 'hrv': 24, 'resting_hr': 65} for r in rows[:6]]
        result = self.score(today(hrv=22, resting_hr=66, sleep_hours=6.8), rows)
        self.assertEqual(result['label'], '偏低')
        self.assertLess(result['components']['hrv'], 0)

    def test_short_sleep_caps_the_label(self):
        rows = history()
        rows[:6] = [{**r, 'hrv': 36, 'resting_hr': 57} for r in rows[:6]]
        self.assertNotEqual(self.score(today(hrv=38, resting_hr=56, sleep_hours=6.2), rows)['label'], '充分')
        self.assertEqual(self.score(today(hrv=38, resting_hr=56, sleep_hours=5.2), rows)['label'], '偏低')

    def test_needs_a_week_of_baseline(self):
        self.assertIsNone(self.score(today(), history(days=5))['score'])
        self.assertIsNone(self.score(today(hrv=0))['score'])


if __name__ == '__main__':
    unittest.main()
