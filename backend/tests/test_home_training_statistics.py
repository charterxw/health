"""Run with unittest against a temporary database. No Google calls or user data."""
import asyncio
import copy
import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import AsyncMock, patch
from zoneinfo import ZoneInfo

from pydantic import ValidationError
from app import database, home_dashboard as h


class HomeTrainingStatistics(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.db = patch.object(database, 'DB_PATH', str(Path(self.folder.name)/'test.sqlite'))
        self.db.start()
        self.clock = patch.object(h, 'now', lambda: datetime(2026, 11, 16, 23, 45, tzinfo=ZoneInfo('America/New_York')))
        self.zone = patch.object(h, 'TZ', ZoneInfo('America/New_York'))
        self.clock.start(); self.zone.start()
        with database.get_db() as c:
            c.executescript('''CREATE TABLE strength_sessions (id TEXT PRIMARY KEY, document_json TEXT, version INTEGER, started_at TEXT, ended_at TEXT, status TEXT);
                              CREATE TABLE strength_templates (id TEXT PRIMARY KEY, document_json TEXT, version INTEGER);''')
            h.schema(c); c.commit()

    def tearDown(self):
        self.zone.stop(); self.clock.stop(); self.db.stop(); self.folder.cleanup()

    def session(self, ident, posture=False, timed=False, legacy=False, status='completed'):
        movement = {'exercise_id':'posture-doorway-left' if posture else 'barbell-bench-press',
                    'tracking':'duration' if timed else 'reps', 'training_type':'mobility' if posture else 'strength',
                    'sets':[{'id':ident+'-set','completed_at':'2026-11-17T04:30:00Z','warmup':False,
                             'duration_seconds':25 if timed else None,'reps':None if timed else 8}]}
        if legacy: movement.pop('training_type')
        return {'id':ident,'template_id':'posture-daily' if posture else 'guided-upper-a','title':ident,
                'status':status,'started_at':'2026-11-17T04:20:00Z','ended_at':'2026-11-17T04:35:00Z',
                'exercises':[movement]}

    def save(self, session):
        with database.get_db() as c:
            c.execute('INSERT INTO strength_sessions VALUES (?,?,1,?,?,?)',
                      (session['id'],json.dumps(session),session['started_at'],session['ended_at'],session['status']));c.commit()

    def today(self):
        report = h.summary()
        return next(d for d in report['days'] if d['date'] == report['date'])

    def test_confirmed_old_template_advances_plan_without_inventing_work(self):
        session=self.session('old-template')
        ids=[x for pair in zip(h.COMPANY,h.HOME) for x in pair]
        templates={key:{'name':key,'exercises':[{'exercise_id':'barbell-bench-press','set_count':3}]} for key in ids}
        slots=[{'template_id':key,'name':key,'exercises':[{'exercise_id':'barbell-bench-press','target':3}]} for key in ids]
        slots[0]['completion_confirmation']={'session_ids':[session['id']],'date':'2026-11-16','reason':'template_mismatch'}
        with database.get_db() as c:
            c.execute('INSERT INTO home_rounds(created_at,document) VALUES (?,?)',('2026-11-16T00:00:00-05:00',json.dumps(slots)))
            c.commit()
        result=h.plan_state([session],templates)
        self.assertTrue(result['slots'][0]['completed'])
        self.assertTrue(result['slots'][0]['completion_confirmed'])
        self.assertEqual((result['slots'][0]['done'],result['slots'][0]['target']),(1,3))
        self.assertEqual(result['slots'][0]['remaining'][0]['target'],2)
        self.assertEqual(result['next']['template_id'],ids[1])
        # A deleted or no-longer-completed source cannot sustain confirmation.
        self.assertFalse(h.plan_state([],templates)['slots'][0]['completed'])
        active=copy.deepcopy(session);active['status']='active'
        self.assertFalse(h.plan_state([active],templates)['slots'][0]['completed'])
        # The confirmation belongs to this round, never to the reusable template.
        with database.get_db() as c:
            c.execute('UPDATE home_rounds SET closed=1');c.commit()
        fresh=h.plan_state([],templates)
        self.assertFalse(fresh['slots'][0]['completed'])
        self.assertNotIn('completion_confirmation',fresh['slots'][0])

    def test_posture_does_not_add_strength_sets_or_energy_windows(self):
        strength=self.session('strength');posture=self.session('posture',posture=True)
        self.save(strength);self.save(posture)
        day=self.today()
        self.assertEqual((day['sets'],day['target']),(1,1))
        self.assertTrue(day['posture']);self.assertEqual(len(day['sessions']),1)
        windows,reliable=h.training_windows([strength,posture],h.now().date(),h.now())
        self.assertTrue(reliable);self.assertEqual(len(windows),1)

    def test_timed_and_legacy_posture_count_once_by_local_date(self):
        self.save(self.session('timed',posture=True,timed=True))
        self.save(self.session('legacy',posture=True,legacy=True))
        day=self.today()
        self.assertTrue(day['posture']);self.assertEqual(len(day['posture_sessions']),2)
        self.assertEqual(day['sets'],0)
        self.assertEqual(sum(d['posture'] for d in h.summary()['days']),1)

    def test_timed_strength_counts_in_home_progress_and_deletion_removes_it(self):
        session=self.session('plank',timed=True)
        session['template_id']='personal-home-e'
        session['exercises'][0]['exercise_id']='forearm-plank'
        self.save(session)
        day=self.today()
        self.assertEqual((day['sets'],day['target']),(1,1))
        self.assertFalse(day['posture'])
        with database.get_db() as c:
            c.execute("DELETE FROM strength_sessions WHERE id='plank'");c.commit()
        self.assertEqual(self.today()['sets'],0)

    def test_optional_e_is_third_day_without_changing_mandatory_slots_or_confirmations(self):
        from app import strength_training as strength
        ids=[x for pair in zip(h.COMPANY,h.HOME) for x in pair]
        templates={key:{'id':key,'name':key,'exercises':[{'exercise_id':'barbell-bench-press','set_count':3}]} for key in ids}
        templates.update({t.id:t.model_dump(mode='json') for t in strength.TEMPLATES if t.id in ['personal-company-e','personal-home-e']})
        with patch.object(h,'now',lambda:datetime(2026,11,16,0,tzinfo=h.TZ)):
            initial=h.plan_state([],templates)
        records=[]
        for i,key in enumerate(ids[:4]):
            s=self.session('main-'+str(i));s['template_id']=key
            s['exercises'][0]['sets']=[{**s['exercises'][0]['sets'][0],'id':f'set-{i}-{n}'} for n in range(3)]
            records.append(s)
        wednesday=datetime(2026,11,18,12,tzinfo=h.TZ)
        with patch.object(h,'now',lambda:wednesday):
            result=h.plan_state(records,templates)
            self.assertEqual([d['letter'] for d in result['schedule']],['A','B','E','C','D'])
            self.assertEqual(result['current']['letter'],'E')
            self.assertTrue(result['current']['optional'])
            self.assertEqual(result['next']['template_id'],h.COMPANY[2])
            self.assertEqual(len(result['slots']),8)
            self.assertEqual(result['target'],initial['target'])
            active=self.session('started-c',status='active');active['template_id']=h.COMPANY[2]
            self.assertEqual(h.plan_state(records+[active],templates)['current']['letter'],'C')
        with patch.object(h,'now',lambda:wednesday+__import__('datetime').timedelta(days=1)):
            self.assertEqual(h.plan_state(records,templates)['current']['letter'],'C')

    def test_wednesday_overview_and_guidance_mark_e_as_optional(self):
        from app import strength_training as strength
        with database.get_db() as c:
            for t in strength.TEMPLATES:
                if t.id in ['personal-company-e','personal-home-e']:
                    c.execute('INSERT INTO strength_templates VALUES (?,?,1)',(t.id,strength.encode(t.model_dump(mode='json'))))
            c.commit()
        with patch.object(h,'now',lambda:datetime(2026,11,18,12,tzinfo=h.TZ)):
            report=h.summary();day=next(d for d in report['days'] if d['date']==report['date'])
            self.assertTrue(day['strength_optional'])
            self.assertFalse(day['strength_planned'])
            self.assertEqual((day['short'],day['target']),('腹',18))
            self.assertIn('可选',report['tip'])

    def test_empty_unchecked_and_warmup_timed_strength_are_excluded(self):
        session=self.session('plank',timed=True)
        item=session['exercises'][0]['sets'][0]
        self.assertEqual(len(h.completed_sets(session)),1)
        for change in [{'duration_seconds':0},{'completed_at':None},{'warmup':True}]:
            candidate=copy.deepcopy(session)
            candidate['exercises'][0]['sets'][0].update(change)
            self.assertEqual(h.completed_sets(candidate),[])

    def test_manual_feedback_cannot_complete_ring_and_deletion_updates_it(self):
        with database.get_db() as c:
            c.execute('INSERT INTO home_feedback(date,posture) VALUES (?,1)',('2026-11-16',));c.commit()
        self.assertFalse(self.today()['posture'])
        self.save(self.session('pose',posture=True,timed=True))
        self.assertTrue(self.today()['posture'])
        with database.get_db() as c:
            c.execute("DELETE FROM strength_sessions WHERE id='pose'");c.commit()
        self.assertFalse(self.today()['posture'])
        with self.assertRaises(ValidationError):h.Feedback.model_validate({'posture':True})
        h.Feedback.model_validate({'energy':'一般','fatigue':'轻'})

    def test_active_empty_discarded_and_warmup_do_not_complete_posture(self):
        active=self.session('active',posture=True,status='active')
        discarded=self.session('discarded',posture=True,status='discarded')
        empty=self.session('empty',posture=True);empty['exercises'][0]['sets'][0]['completed_at']=None
        warmup=self.session('warmup',posture=True);warmup['exercises'][0]['sets'][0]['warmup']=True
        for session in [active,discarded,empty,warmup]:self.save(session)
        self.assertFalse(self.today()['posture'])

    def test_activity_subtracts_strength_only_and_never_queries_posture(self):
        strength=self.session('strength');posture=self.session('posture',posture=True)
        async def energy(a,b):return 100 if a.hour==0 else 20
        with patch.object(h,'roll_energy',energy):data=asyncio.run(h.activity_snapshot([strength,posture]))
        self.assertEqual(data[0]['activity'],80);self.assertEqual(data[0]['strength'],20)
        self.assertEqual(len(data[0]['windows']),1)

    def test_failed_read_preserves_measured_cutoff_only_with_matching_windows(self):
        row={'date':'2026-11-16','activity':80,'windows':[['start','end']],'cutoff':'original'}
        miss={**row,'activity':None,'cutoff':'later'}
        self.assertEqual(h.merge_activity_snapshot([row],[miss]),[row])
        changed={**miss,'windows':[['different','end']]}
        self.assertIsNone(h.merge_activity_snapshot([row],[changed])[0]['activity'])

    def test_recent_metrics_do_not_prevent_repairing_missing_activity(self):
        h.save_snapshot('metrics',[])
        h.save_snapshot('activity',[{'date':'2026-11-16','activity':None,'windows':[]}])
        calls=[]
        async def activity(_):
            calls.append(True)
            return [{'date':'2026-11-16','activity':80,'windows':[],'cutoff':h.now().isoformat()}]
        with patch.object(h.gh,'is_authenticated',lambda:True),patch.object(h,'activity_snapshot',activity),patch.object(h,'freshness_snapshot',AsyncMock(return_value={})):
            asyncio.run(h.refresh())
            asyncio.run(h.refresh())
        self.assertEqual(calls,[True])
        self.assertEqual(h.snapshot('activity')[0][0]['activity'],80)


if __name__ == '__main__':unittest.main()
