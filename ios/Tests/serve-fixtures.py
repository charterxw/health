#!/usr/bin/env python3
"""Loopback-only native UI fixtures. Never contacts the production service."""
import copy
import json
import threading
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

RUNS = {}
LOCK = threading.RLock()

def stamp(offset=0):
    return (datetime.now(timezone.utc) + timedelta(seconds=offset)).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

def day(offset=0):
    return (datetime.now().date() + timedelta(days=offset)).isoformat()

EXERCISES = [dict(id='pulldown', name='单手下拉', equipment='绳索', load_mode='external', tracking='reps', training_type='strength', muscles=['背部'], primary_muscles=['upper-back'], instructions=['调整座椅，保持躯干稳定。', '控制下拉和还原。']),
             dict(id='posture-test', name='死虫式保持', equipment='瑜伽垫', load_mode='bodyweight', tracking='duration', training_type='mobility', instructions=['稳定骨盆，保持自然呼吸。'])]
TEMPLATES = [dict(id='back', name='背部力量训练', exercises=[dict(exercise_id='pulldown', set_count=4, rest_seconds=90, unit='lb', target_reps=8, warmup_count=0)]),
             dict(id='posture-test', name='体态计时练习', exercises=[dict(exercise_id='posture-test', set_count=2, rest_seconds=30, unit='kg', target_seconds=30, warmup_count=0)])]

def new_run():
    rows = [dict(id=str(uuid4()), weight=50, reps=8, duration_seconds=None, completed_at=None, warmup=False, hard_reps=None) for _ in range(4)]
    session = dict(id=str(uuid4()), template_id='back', title='背部力量训练', started_at=stamp(-180), ended_at=None, timezone='America/New_York', status='active', paused_at=None, paused_seconds=0, rest_until=None, rest_set_id=None, notes='', template_notes='', duration_min=None, duration_max=None,
                   exercises=[dict(id=str(uuid4()), exercise_id='pulldown', name='单手下拉', equipment='绳索', load_mode='external', unit='lb', tracking='reps', training_type='strength', rest_seconds=90, effort=None, primary_muscles=['upper-back'], secondary_muscles=[], prescription=None, sets=rows)])
    return dict(authenticated=False, records={session['id']:dict(session=session, version=1)}, deleted=[], failed_once=False, offline=False, saves=0, goals=dict(dailyActivity=300, weeklyActivity=2100, weeklyStrength=4, weeklyPosture=4), feedback={})

def home(run):
    metrics = [dict(date=day(i), steps=6240+i*120, distance_km=4.8, calories_burned=310, active_minutes=22, sleep_hours=7.5+i*.03, hrv=49, resting_hr=59) for i in range(-13,1)]
    active = next((r['session'] for r in run['records'].values() if r['session']['status']=='active'),None)
    slot = dict(template_id='back', name='背部力量训练', short='背', done=0, target=4, completed=False, remaining=[dict(exercise_id='pulldown', target=4)])
    return dict(date=day(), timezone='America/New_York', today=metrics[-1], metrics=metrics, tip='按原计划训练，照常遛狗散步。',
                action=dict(session_id=active['id']) if active else dict(template_id='back', remaining=slot['remaining']),
                plan=dict(id=1, slots=[slot], current=dict(slots=[slot]), schedule=[dict(letter='A',day=1,optional=False,slots=[slot])], next=slot, done=0,target=4),
                days=[dict(date=day(i),activity=250 if i<=0 else None,sets=0,target=4,short='练',posture=False,goals=run['goals'],sessions=[]) for i in range(-3,4)],
                sleeps=[], sleep=None,weights=[dict(date=day(),weight_kg=72.5)],walks=[], feedback=run['feedback'], goals=run['goals'],step_goal=dict(target=run.get('steps',8000)),next_effective=day(7),
                freshness=dict(records=dict(steps=dict(observed_at=stamp(-900))),device=dict(last_sync_at=stamp(-1200))),sources={})

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def json(self, value, status=200, cookie=None):
        raw=json.dumps(value,ensure_ascii=False).encode(); self.send_response(status)
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(raw)));self.send_header('Cache-Control','no-store')
        if cookie:self.send_header('Set-Cookie',cookie)
        self.end_headers();self.wfile.write(raw)
    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}')
    def do_GET(self):self.handle_request()
    def do_POST(self):self.handle_request()
    def do_PUT(self):self.handle_request()
    def handle_request(self):
        try:
            with LOCK:self.route()
        except (BrokenPipeError,ConnectionResetError):pass
        except Exception as e:
            print(type(e).__name__,str(e),flush=True);self.json(dict(detail='Fixture error'),500)
    def route(self):
        path=self.path.split('?')[0]
        if path.startswith('/__test/'):
            parts=path.split('/'); ident=parts[2]; run=RUNS.setdefault(ident,new_run())
            if self.command=='POST':
                value=self.body()
                if 'offline' in value:run['offline']=value['offline']
                if value.get('conflict'):
                    for row in run['records'].values():row['version']+=1;row['session']['notes']='另一客户端保留的笔记'
                if value.get('delete'):
                    for ident,row in list(run['records'].items()):run['deleted'].append(dict(id=ident,version=row['version']+1,deleted_at=stamp()));del run['records'][ident]
            return self.json(run)
        ident=self.headers.get('X-Health-Test-ID','')
        if not ident:return self.json(dict(detail='Fixture ID required'),400)
        run=RUNS.setdefault(ident,new_run())
        if run['offline']:return self.json(dict(detail='Offline fixture'),503)
        if path=='/api/auth/app-status':
            if self.headers.get('X-Health-Test-Retry')=='1' and not run['failed_once']:
                run['failed_once']=True;return self.json(dict(detail='Retry fixture'),503)
            return self.json(dict(authenticated=run['authenticated'] and 'dashboard_session='+ident in self.headers.get('Cookie','')))
        if path=='/api/auth/app-login':
            value=self.body();good=value.get('username')=='test' and value.get('password')=='sample-password'
            run['authenticated']=good
            return self.json(dict(authenticated=good),200 if good else 401,cookie=f'dashboard_session={ident}; Max-Age=86400; Path=/; HttpOnly; SameSite=Lax' if good else None)
        if not run['authenticated'] or 'dashboard_session='+ident not in self.headers.get('Cookie',''):return self.json(dict(detail='Please sign in'),401)
        if path=='/api/auth/logout':run['authenticated']=False;return self.json(dict(authenticated=False),cookie='dashboard_session=; Max-Age=0; Path=/')
        if path=='/api/auth/status':return self.json(dict(authenticated=True))
        if path=='/api/integrations/status':return self.json(dict(chatgpt=dict(connected=True),notifications=dict(enabled=False)))
        if path.startswith('/api/home'):
            if path=='/api/home/brief':return self.json(dict(status='ready',title='早间观察',sentences=['昨夜睡眠 7 小时 30 分钟，接近近期水平。']))
            if path=='/api/home/feedback':run['feedback']=self.body()
            if path=='/api/home/goals':run['goals']=self.body()
            if path=='/api/home/step-goal':run['steps']=self.body()['target']
            return self.json(home(run))
        if path=='/api/strength/catalog':return self.json(dict(exercises=EXERCISES,templates=[dict(template=t,version=1) for t in TEMPLATES]))
        if path=='/api/strength/session-deletions':return self.json(run['deleted'])
        if path=='/api/strength/sessions':return self.json(list(run['records'].values()))
        if path.startswith('/api/strength/templates/') and self.command=='PUT':value=self.body();return self.json(dict(template=value['template'],version=value['expected_version']+1))
        if path.startswith('/api/strength/exercises/') and path.endswith('/history'):return self.json(dict(records=[]))
        if path=='/api/workouts/training/archive':return self.json([])
        if path=='/api/workouts/archive':return self.json(dict(training=[],exercises=[]))
        if path=='/api/insights/archive':return self.json([dict(id=1,date=day(),title='早间观察',report=dict(findings=[dict(headline='昨夜睡眠接近近期水平',body='记录了 7 小时 30 分钟睡眠。',evidence=['昨夜实际睡眠 450 分钟'],confidence='medium')]))])
        if path.startswith('/api/strength/sessions/'):
            ident=path.split('/')[4];record=run['records'].get(ident)
            if path.endswith('/delete'):
                if not record:return self.json(dict(detail='Deleted'),410)
                value=self.body()
                if record['version']!=value['expected_version']:return self.json(dict(detail='Version conflict'),409)
                tomb=dict(id=ident,version=record['version']+1,deleted_at=stamp());run['deleted'].append(tomb);del run['records'][ident];return self.json(tomb)
            if path.endswith('/physiology'):return self.json(dict(status='ready',metrics=dict(active_energy=dict(value=92)),heart_rate=dict(summary=dict(sample_count=3,mean_bpm=120,min_bpm=110,max_bpm=130),chart=[dict(at=stamp(-120),mean_bpm=110),dict(at=stamp(-60),mean_bpm=None),dict(at=stamp(),mean_bpm=130)],sources=[])))
            if path.endswith('/review'):return self.json(dict(status='ready',analysis={k:dict(text=v,evidence_ids=[]) for k,v in [('today','本次已完成的工作组已记录。'),('trend','与已有记录分别对照。'),('next','下次保持负荷，按实际完成记录。')]},evidence=dict(facts=[])))
            if self.command=='PUT':
                value=self.body()
                if any(t['id']==ident for t in run['deleted']):return self.json(dict(detail='Deleted'),410)
                version=record['version'] if record else 0
                if version!=value['expected_version']:return self.json(dict(detail='Version conflict'),409)
                record=dict(session=value['session'],version=version+1);run['records'][ident]=record;run['saves']+=1
            if not record:return self.json(dict(detail='Not found'),404)
            return self.json(record)
        self.json(dict(detail='Unknown fixture route'),404)

if __name__=='__main__':
    print('Native fixtures ready on 127.0.0.1:43189',flush=True)
    ThreadingHTTPServer(('127.0.0.1',43189),Handler).serve_forever()
