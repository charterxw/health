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

    def plan_templates(self, store=False):
        from app import strength_training as strength
        templates={t.id:t.model_dump(mode='json') for t in strength.TEMPLATES if t.id.startswith('pine-')}
        if store:
            with database.get_db() as c:
                for key,doc in templates.items():
                    c.execute('INSERT INTO strength_templates VALUES (?,?,1)',(key,strength.encode(doc)))
                c.commit()
        return templates

    def plan_session(self, ident, template, sets, when='2026-11-17T18:00:00Z'):
        movements,left=[],sets
        for m in template['exercises']:
            work=m['set_count']-(m.get('warmup_count') or 0)
            rows=[{'id':f'{ident}-{m["exercise_id"]}-{n}','completed_at':when if n<min(work,left) else None,'warmup':False,'reps':10,'weight':20}
                  for n in range(work)]
            left-=min(work,left)
            movements.append({'exercise_id':m['exercise_id'],'tracking':'reps','training_type':'strength','sets':rows})
        return {'id':ident,'template_id':template['id'],'title':template['name'],'status':'completed',
                'started_at':when,'ended_at':when,'exercises':movements}

    def test_plan_days_accept_halves_or_a_whole_day_session(self):
        templates=self.plan_templates()
        start=h.plan_state([],templates)
        self.assertEqual([d['letter'] for d in start['schedule']],['A','B','E','C','D'])
        self.assertEqual((start['done'],start['target']),(0,90))
        self.assertEqual(start['next']['template_id'],'pine-a-company')
        self.assertEqual(len(start['slots']),20)
        records=[self.plan_session('a-company',templates['pine-a-company'],9),
                 self.plan_session('b-gym',templates['pine-b-gym'],18),
                 self.plan_session('e-house',templates['pine-e-house'],5)]
        result=h.plan_state(records,templates)
        a,b,e=result['schedule'][:3]
        self.assertTrue(a['slots'][0]['completed']);self.assertFalse(a['completed'])
        self.assertEqual(result['next']['template_id'],'pine-a-home')
        self.assertEqual(result['current']['letter'],'A')
        self.assertTrue(b['completed']);self.assertTrue(all(x['completed'] for x in b['slots']))
        self.assertEqual((e['done'],e['slots'][0]['done'],e['slots'][1]['done']),(5,5,0))
        self.assertEqual(result['done'],9+18+5)
        # A whole-day session counts once even when both halves are also present.
        extra=h.plan_state(records+[self.plan_session('b-company',templates['pine-b-company'],9)],templates)
        self.assertEqual(extra['schedule'][1]['done'],18)

    def test_previous_plan_round_is_closed_when_the_new_plan_starts(self):
        templates=self.plan_templates()
        with database.get_db() as c:
            c.execute('INSERT INTO home_rounds(created_at,document) VALUES (?,?)',('2026-11-09T00:00:00-05:00',json.dumps([{'template_id':'guided-upper-a'}])))
            c.commit()
        result=h.plan_state([],templates)
        with database.get_db() as c:
            rounds=c.execute('SELECT id,closed FROM home_rounds ORDER BY id').fetchall()
        self.assertEqual([tuple(r) for r in rounds],[(1,1),(2,0)])
        self.assertEqual(result['id'],2)

    def test_week_rows_follow_the_round_and_saturday_is_optional(self):
        templates=self.plan_templates(store=True)
        with patch.object(h,'now',lambda:datetime(2026,11,16,9,tzinfo=h.TZ)):
            report=h.summary()
        days=report['days']
        self.assertEqual([d['short'] for d in days],['肩','背','腹','肩','背','选','休'])
        self.assertEqual([d['target'] for d in days[:5]],[18]*5)
        self.assertTrue(all(d['strength_planned'] for d in days[:5]))
        self.assertTrue(days[5]['strength_optional']);self.assertFalse(days[5]['strength_planned'])
        self.assertEqual(report['action']['template_id'],'pine-a-company')
        # Once today's day is finished, tomorrow takes the next day of the round.
        self.save(self.plan_session('mon',templates['pine-a-gym'],18,'2026-11-16T15:00:00Z'))
        with patch.object(h,'now',lambda:datetime(2026,11,16,18,tzinfo=h.TZ)):
            report=h.summary()
        self.assertEqual([d['short'] for d in report['days'][:5]],['肩','背','腹','肩','背'])
        self.assertEqual(report['days'][0]['sets'],18)
        self.assertEqual(report['action']['template_id'],'pine-b-company')

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
