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


class BriefRecoveryWordingTests(unittest.TestCase):
    def test_recovery_state_agrees_with_the_score_and_names_drivers(self):
        from app.home_brief import score_state
        text = score_state({'score': 59, 'label': '偏低', 'components': {'hrv': -0.3, 'resting_hr': -0.2, 'sleep': -1.1}})
        self.assertIn('恢复指数59，状态偏低', text)
        self.assertIn('睡眠（对照8小时目标）', text)
        self.assertNotIn('HRV', text)
        self.assertIn('正常范围', score_state({'score': 70, 'label': '平稳', 'components': {}}))

    def test_weight_trend_reports_monthly_pace_against_the_band(self):
        from app.home_brief import weight_trend
        rows = [{'date': f'2026-11-{d:02d}', 'kg': 68 + 0.04 * d} for d in range(1, 21)]
        text = weight_trend(rows, '2026-11-20')
        self.assertIn('每月约+1.2公斤', text)
        self.assertIn('偏快', text)
        self.assertIsNone(weight_trend(rows[-5:], '2026-11-20'))


class BriefOptionalDayTests(unittest.TestCase):
    def test_optional_day_lists_its_own_template(self):
        from unittest import mock
        from app import home_brief, home_dashboard
        template = {'id': 'pine-sat-optional', 'name': '周六 · 选练｜肩宽·后束·三头', 'duration_min': 20, 'duration_max': 25,
                    'exercises': [{'exercise_id': 'dumbbell-lateral-raise', 'set_count': 5, 'warmup_count': 1},
                                  {'exercise_id': 'chest-supported-reverse-fly', 'set_count': 3, 'warmup_count': 0}]}
        data = {'date': '2026-11-21', 'today': {}, 'days': [{'date': '2026-11-21', 'strength_optional': True, 'sets': 0}],
                'plan': {'current': {'slots': [{'name': 'A · 公司｜肩宽·三头', 'target': 9}]}}}
        facts = []
        with mock.patch.object(home_dashboard, 'load_training', return_value=([], {'pine-sat-optional': template})):
            home_brief.context_facts(data, 'morning', lambda key, kind, text: facts.append((key, text)))
        plan = dict(facts)['plan-today']
        self.assertIn('可选的选练日：肩宽·后束·三头', plan)
        self.assertIn('7个工作组', plan)
        self.assertNotIn('公司', plan)
