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
