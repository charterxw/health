import copy
import unittest
from datetime import datetime, timezone
from uuid import uuid4
from pydantic import ValidationError
from app.strength_training import StrengthSet
from app.session_review import evidence
from test_training_ux import sample


class SetFeedbackTests(unittest.TestCase):
    def test_optional_integer_preserves_zero_and_rejects_invalid_values(self):
        base={'id':str(uuid4()),'reps':8,'weight':20}
        self.assertIsNone(StrengthSet.model_validate(base).hard_reps)
        for value in [None,0,2]:
            self.assertEqual(StrengthSet.model_validate({**base,'hard_reps':value}).model_dump()['hard_reps'],value)
        for value in [-1,1001,1.5,True,'2']:
            with self.assertRaises(ValidationError):StrengthSet.model_validate({**base,'hard_reps':value})

    def test_review_receives_reported_values_only_for_valid_completed_work(self):
        doc=sample();rows=doc['exercises'][0]['sets']
        rows[0]['hard_reps']=0;rows[1]['hard_reps']=2
        result=evidence(doc,[],datetime(2026,11,17,tzinfo=timezone.utc))
        feedback=next(f for f in result['facts'] if f['kind']=='effort')
        self.assertEqual([r['hard_reps'] for r in feedback['sets']],[0,2])
        self.assertIn('没有明显吃力',feedback['text'])
        rows[0]['warmup']=True;rows[1]['completed_at']=None;rows[2]['hard_reps']=9
        self.assertFalse(any(f['kind']=='effort' for f in evidence(doc,[],datetime(2026,11,17,tzinfo=timezone.utc))['facts']))

    def test_prior_feedback_respects_template_and_weight_context(self):
        old=sample('a');old['exercises'][0]['sets'][0]['hard_reps']=3
        current=copy.deepcopy(old);current['id']=str(uuid4());current['started_at']='2026-11-08T12:00:00Z';current['ended_at']='2026-11-08T12:30:00Z'
        for row in current['exercises'][0]['sets']:row['completed_at']=current['ended_at']
        current['exercises'][0]['sets'][0]['hard_reps']=1
        result=evidence(current,[old],datetime(2026,11,17,tzinfo=timezone.utc))
        self.assertEqual(len([f for f in result['facts'] if f['kind']=='effort']),2)
        old['template_id']='b'
        result=evidence(current,[old],datetime(2026,11,17,tzinfo=timezone.utc))
        self.assertEqual(len([f for f in result['facts'] if f['kind']=='effort']),1)
