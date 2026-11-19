import unittest

from app.home_brief import validate

FACTS = {'period': 'morning', 'facts': [
    {'id': 'sleep-today', 'kind': 'observation', 'text': '昨夜睡眠6小时15分。'},
    {'id': 'recovery-state', 'kind': 'recovery', 'text': '结合睡眠和体感描述恢复。'},
    {'id': 'hrv-trend', 'kind': 'trend', 'text': '近7个完整日HRV均值23.3毫秒。'},
    {'id': 'guidance', 'kind': 'guidance', 'text': '今天有力量训练安排。'},
]}


def report(*lines):
    return {'sentences': [{'text': text, 'evidence_ids': list(refs)} for text, refs in lines]}


class BriefEvidenceTests(unittest.TestCase):
    def test_unknown_ids_are_dropped_when_real_evidence_remains(self):
        value = report(('昨夜睡眠偏短，恢复状态一般。', ['recovery-state', 'sleep-today', 'sleep-hours-today']),
                       ('近期HRV大体平稳。', ['hrv-trend']),
                       ('今天照常力量训练。', ['guidance', 'made-up']))
        result = validate(value, FACTS)
        self.assertEqual(result['sentences'][0]['evidence_ids'], ['recovery-state', 'sleep-today'])
        self.assertEqual(result['sentences'][2]['evidence_ids'], ['guidance'])

    def test_sentence_without_any_real_evidence_is_rejected(self):
        value = report(('昨夜睡眠偏短，恢复状态一般。', ['recovery-state', 'sleep-today']),
                       ('近期HRV大体平稳。', ['hrv-trend']),
                       ('今天照常力量训练。', ['made-up']))
        with self.assertRaisesRegex(ValueError, 'evidence'):
            validate(value, FACTS)


if __name__ == '__main__':
    unittest.main()


class BriefContextFactTests(unittest.TestCase):
    def test_sleep_stages_plan_and_yesterday_training_are_supplied(self):
        from datetime import datetime
        from unittest import mock
        from app import home_brief, home_dashboard
        now = datetime(2026, 11, 19, 9, 0, tzinfo=home_dashboard.TZ)
        session = {'status': 'completed', 'title': 'E · 家庭｜腹部·小腿', 'started_at': '2026-11-18T21:11:54Z', 'ended_at': '2026-11-18T21:30:22Z',
                   'paused_seconds': 0, 'exercises': [{'name': '坐姿哑铃提踵', 'tracking': 'reps', 'sets': [
                       {'reps': 20, 'weight': 20, 'completed_at': '2026-11-18T21:20:00Z', 'hard_reps': 2},
                       {'reps': 20, 'weight': 20, 'completed_at': '2026-11-18T21:25:00Z'}]}]}
        data = {'date': '2026-11-19', 'today': {'steps': 1292}, 'step_goal': {'target': 6500},
                'sleep': {'total_deep_mins': 80, 'total_rem_mins': 119, 'total_light_mins': 267, 'awake_periods': 3},
                'days': [{'date': '2026-11-19', 'strength_planned': True, 'sets': 0}],
                'plan': {'current': {'slots': [{'name': 'C · 公司｜上胸·肩·三头', 'target': 9, 'done': 0},
                                               {'name': 'C · 家庭｜肩·三头·胸', 'target': 9, 'done': 0}]}}}
        facts = []
        with mock.patch.object(home_dashboard, 'now', return_value=now), mock.patch.object(home_dashboard, 'load_training', return_value=([session], {})):
            home_brief.context_facts(data, 'morning', lambda key, kind, text: facts.append((key, text)))
        found = dict(facts)
        self.assertIn('深睡80分钟', found['sleep-stages'])
        self.assertIn('公司上胸·肩·三头（9组，未开始）', found['plan-today'])
        self.assertIn('腹部·小腿完成2/2组，用时18分钟，自报最后几次吃力1组', found['training-yesterday'])
        self.assertIn('日目标6500步', found['steps-goal'])
