import json
import tempfile
import unittest
from datetime import datetime,timezone
from pathlib import Path
from unittest.mock import patch
from app import database,strength_training as strength,scheduler
from app.session_review import evidence
from test_training_ux import sample


class ActionableReviewTests(unittest.TestCase):
    def test_off_progression_contains_actual_weights_reps_and_next_target(self):
        doc=sample();doc['exercises'][0]['sets'][-1]['reps']=6
        data=evidence(doc,[],datetime(2026,11,17,tzinfo=timezone.utc))
        current=next(f for f in data['facts'] if f['kind']=='current')
        self.assertIn('100磅×6次',current['text'])
        action=next(f for f in data['facts'] if f['id']==data['next_focus'])
        self.assertIn('第3组尝试100磅×7次',action['text'])
        doc['exercises'][0]['sets'][-1]['hard_reps']=2
        action=next(f for f in evidence(doc,[],datetime(2026,11,17,tzinfo=timezone.utc))['facts'] if f['kind']=='next')
        self.assertIn('先稳住100磅×6次',action['text'])

    def test_incomplete_and_unstarted_movements_get_specific_next_steps(self):
        doc=sample();doc['exercises'][0]['sets'][-1]['completed_at']=None
        action=next(f for f in evidence(doc,[],datetime(2026,11,17,tzinfo=timezone.utc))['facts'] if f['kind']=='next')
        self.assertIn('第3组',action['text']);self.assertIn('100磅×8次',action['text'])
        for row in doc['exercises'][0]['sets']:row['completed_at']=None
        self.assertTrue(any(f['kind']=='next' for f in evidence(doc,[],datetime(2026,11,17,tzinfo=timezone.utc))['facts']))

    def test_saving_strength_workouts_does_not_schedule_sensor_collection(self):
        with tempfile.TemporaryDirectory() as folder,patch.object(database,'DB_PATH',str(Path(folder)/'test.sqlite')):
            database.init_db()
            doc=sample();movement=doc['exercises'][0]
            with database.get_db() as c:
                c.execute('INSERT INTO strength_exercises VALUES (?,?)',(movement['exercise_id'],json.dumps({'id':movement['exercise_id']})));c.commit()
            request=strength.SaveSession.model_validate({'expected_version':0,'session':doc})
            strength.save_session(request);strength.save_session(strength.SaveSession.model_validate({'expected_version':1,'session':doc}))
            with database.get_db() as c:
                self.assertEqual(c.execute('SELECT COUNT(*) FROM strength_physiology').fetchone()[0],0)

    def test_scheduler_no_longer_registers_strength_collection(self):
        with patch.object(scheduler.scheduler,'add_job') as add,patch.object(scheduler.scheduler,'start'):
            scheduler.start_scheduler()
        self.assertNotIn('strength_physiology',[c.kwargs.get('id') for c in add.call_args_list])
