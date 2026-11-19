import copy
import unittest
from datetime import datetime, timezone
from uuid import uuid4
from app.strength_training import Session
from app.session_review import evidence


def sample(template='b'):
    started='2026-11-01T12:00:00Z';ended='2026-11-01T12:30:00Z'
    movement={'id':str(uuid4()),'exercise_id':'lat-pulldown','name':'示例下拉','load_mode':'external','unit':'lb','rest_seconds':120,'sets':[{'id':str(uuid4()),'weight':100,'reps':8,'warmup':False,'completed_at':ended} for _ in range(3)]}
    return {'id':str(uuid4()),'title':'示例训练','template_id':template,'started_at':started,'ended_at':ended,'status':'completed','timezone':'UTC','exercises':[movement]}


class TrainingUXTests(unittest.TestCase):
    def test_posture_is_separate_from_strength_session_totals(self):
        current=sample()
        posture=copy.deepcopy(current['exercises'][0])
        posture.update(id=str(uuid4()),exercise_id='posture-wall-slide',training_type='mobility',load_mode='bodyweight')
        current['exercises'].append(posture)
        mixed=evidence(current,[],datetime(2026,11,17,tzinfo=timezone.utc))
        self.assertEqual((mixed['completed'],mixed['planned']),(3,3))
        current['exercises']=[posture]
        practice=evidence(current,[],datetime(2026,11,17,tzinfo=timezone.utc))
        self.assertEqual((practice['completed'],practice['planned']),(3,3))

    def test_optional_rest_source_and_weight_note_round_trip(self):
        doc=sample();doc['rest_set_id']=doc['exercises'][0]['sets'][0]['id'];doc['exercises'][0]['weight_note']='每只哑铃'
        parsed=Session.model_validate(doc).model_dump(mode='json')
        self.assertEqual(parsed['rest_set_id'],doc['rest_set_id'])
        self.assertEqual(parsed['exercises'][0]['weight_note'],'每只哑铃')
        legacy=Session.model_validate(sample()).model_dump(mode='json')
        self.assertIsNone(legacy['rest_set_id'])

    def test_ai_evidence_excludes_other_template_and_changed_order(self):
        old=sample('b');current=sample('d');current['started_at']='2026-11-08T12:00:00Z';current['ended_at']='2026-11-08T12:30:00Z'
        for s in current['exercises'][0]['sets']:s['reps']=10;s['completed_at']=current['ended_at']
        result=evidence(current,[old],datetime(2026,11,17,tzinfo=timezone.utc))
        self.assertFalse(any(f['kind']=='comparison' for f in result['facts']))
        old['template_id']='d'
        result=evidence(current,[old],datetime(2026,11,17,tzinfo=timezone.utc))
        self.assertTrue(any(f['kind']=='comparison' for f in result['facts']))
        prefix=copy.deepcopy(old['exercises'][0]);prefix['exercise_id']='curl';prefix['id']=str(uuid4());old['exercises'].insert(0,prefix)
        result=evidence(current,[old],datetime(2026,11,17,tzinfo=timezone.utc))
        self.assertFalse(any(f['kind']=='comparison' for f in result['facts']))
