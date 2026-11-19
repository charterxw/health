#!/usr/bin/env python3
"""Build synthetic layout data from the current public exercise/program source.
The generated Swift is compiled only in simulator DEBUG builds. Never loads user data.
"""
import json
from pathlib import Path
from datetime import datetime,timedelta,timezone
from uuid import uuid5,NAMESPACE_DNS
ROOT=Path(__file__).resolve().parents[2]
data=ROOT/'backend/app/data'
ex=json.loads((data/'exercises.json').read_text())+json.loads((data/'posture_exercises.json').read_text())
programs=[]
for name in ['programs.json','supplemental_programs.json','posture_programs.json']:programs+=json.loads((data/name).read_text())
by_id={e['id']:e for e in ex};templates={t['id']:t for t in programs}
company=dict(a='guided-upper-a',b='guided-lower-a',c='guided-upper-b',d='guided-lower-b',e='personal-company-e')
def program_id(place,letter):return company[letter] if place=='company' else f'personal-home-{letter}'
reference=datetime(2026,11,18,17,0,tzinfo=timezone(timedelta(hours=-5)))
def day(n):return (reference+timedelta(days=n)).date().isoformat()
def stamp(n=0):return (reference+timedelta(minutes=n)).isoformat()
def uid(s):return str(uuid5(NAMESPACE_DNS,'pine-design-'+s))
def session(template_id,offset,index):
 t=templates[template_id];start=reference+timedelta(days=offset,hours=-3,minutes=index*31)
 result=dict(id=uid(str(index)+template_id),template_id=t['id'],title=t['name'],started_at=start.isoformat(),ended_at=(start+timedelta(minutes=24,seconds=18)).isoformat(),timezone='America/New_York',status='completed',paused_at=None,paused_seconds=0,rest_until=None,rest_set_id=None,notes='',template_notes=t.get('notes',''),duration_min=t.get('duration_min'),duration_max=t.get('duration_max'),exercises=[])
 for mi,p in enumerate(t['exercises']):
  e=by_id[p['exercise_id']];timed=e.get('tracking')=='duration';warm=p.get('warmup_count') or 0
  m=dict(id=uid(f'{index}-{mi}'),exercise_id=e['id'],name=e['name'],equipment=e.get('equipment',''),load_mode=e.get('load_mode','external'),tracking=e.get('tracking','reps'),training_type=e.get('training_type','strength'),unit=p.get('unit','lb'),rest_seconds=p.get('rest_seconds',90),primary_muscles=e.get('primary_muscles',[]),secondary_muscles=e.get('secondary_muscles',[]),effort=None,prescription=None,sets=[])
  for si in range(p['set_count']):m['sets'].append(dict(id=uid(f'{index}-{mi}-{si}'),weight=None if timed or m['load_mode']=='bodyweight' else 35+mi*5,reps=None if timed else 10,duration_seconds=p.get('target_seconds',30) if timed else None,completed_at=(start+timedelta(minutes=mi*2+si+1)).isoformat(),warmup=si<warm,hard_reps=None))
  result['exercises'].append(m)
 return dict(session=result,version=1)
goals=dict(dailyActivity=400,weeklyActivity=2800,weeklyStrength=4,weeklyPosture=4)
slots=[]
for pair in 'abcd':
 for place in ['company','home']:
  t=templates[program_id(place,pair)];target=sum(p['set_count']-(p.get('warmup_count') or 0) for p in t['exercises']);done=target if pair in 'ab' else 0
  slots.append(dict(template_id=t['id'],name=t['name'],short='家' if place=='home' else pair.upper(),done=done,target=target,completed=done==target,exercises=[dict(exercise_id=p['exercise_id'],target=p['set_count']-(p.get('warmup_count') or 0)) for p in t['exercises']],remaining=[] if done else [dict(exercise_id=p['exercise_id'],target=p['set_count']-(p.get('warmup_count') or 0)) for p in t['exercises']]))
schedule=[dict(letter=letter.upper(),day=i+1,optional=False,slots=slots[i*2:i*2+2]) for i,letter in enumerate('abcd')]
optional=[]
for place in ['company','home']:
 t=templates[f'personal-{place}-e'];target=sum(p['set_count']-(p.get('warmup_count') or 0) for p in t['exercises']);optional.append(dict(template_id=t['id'],name=t['name'],short='腹',optional=True,target=target,done=target,completed=True,remaining=[]))
schedule.insert(2,dict(letter='E',day=3,optional=True,slots=optional))
metrics=[dict(date=day(i),steps=5400+i*85,calories_burned=310,active_minutes=24,distance_km=4.1,sleep_hours=7.6,hrv=52+i*.2,resting_hr=58) for i in range(0,-28,-1)]
sleeps=[]
for n in range(7):
 start=reference.replace(hour=23,minute=40)-timedelta(days=n+1);at=start;stages=[]
 for name,minutes in [('LIGHT',25),('DEEP',35),('LIGHT',60),('REM',30),('AWAKE',5),('LIGHT',45),('DEEP',30),('LIGHT',55),('REM',45),('LIGHT',80),('REM',50)]:
  end=at+timedelta(minutes=minutes);stages.append(dict(stage=name,startTime=at.isoformat(),endTime=end.isoformat()));at=end
 sums={name:sum((datetime.fromisoformat(s['endTime'])-datetime.fromisoformat(s['startTime'])).total_seconds()/60 for s in stages if s['stage']==name) for name in ['LIGHT','DEEP','REM','AWAKE']}
 sleeps.append(dict(date=day(-n),is_nap=False,minutes_asleep=sum(sums[k] for k in ['LIGHT','DEEP','REM']),minutes_in_bed=sum(sums.values()),total_awake_mins=sums['AWAKE'],total_rem_mins=sums['REM'],total_light_mins=sums['LIGHT'],total_deep_mins=sums['DEEP'],sleep_efficiency_percent=99,spo2_average=97.1,spo2_lower_bound=95.2,spo2_upper_bound=98.4,respiratory_rate=14.1,skin_temperature_delta_c=.25,sleep_latency_minutes=0,awake_periods=2,short_awakenings=7,stages=stages))
records=[session('personal-home-e',0,0),session('personal-company-e',0,1),session('posture-daily',-1,2),session('personal-home-b',-1,3),session('guided-lower-a',-1,4)]
days=[]
for i,offset in enumerate(range(-2,5)):
 days.append(dict(date=day(offset),activity=[420,470,285,None,None,None,None][i],total_energy=[420,560,310,None,None,None,None][i],strength_energy=0 if offset<0 else None,cutoff=stamp(),sets=18 if offset<=0 else 0,target=18 if i<5 else 0,short=['家','家','腹','上','背','休','休'][i],posture=i<2,posture_recorded=i<2,posture_planned=i in [0,1,3,6],strength_planned=i<5,strength_optional=i==2,goals=goals,sessions=[dict(id=r['session']['id'],title=r['session']['title']) for r in records if r['session']['started_at'].startswith(day(offset)) and not r['session']['template_id'].startswith('posture-')],posture_sessions=[]))
home=dict(date=day(0),timezone='America/New_York',today=metrics[0],metrics=metrics,sleep=sleeps[0],sleeps=sleeps,weights=[dict(date=day(0),kg=72.5)],walks=[],days=days,recovery=dict(score=84,label='平稳',hrv_baseline=49,rhr_baseline=59,caution=False),feedback={},plan=dict(id=1,slots=slots,done=sum(s['done'] for s in slots),target=sum(s['target'] for s in slots),next=slots[4],current=schedule[3],schedule=schedule),action=dict(template_id=slots[4]['template_id'],remaining=slots[4]['remaining']),step_goal=dict(target=6500),goals=goals,next_effective=day(5),sources={k:dict(fetched_at=stamp(-5)) for k in ['metrics','sleep','weight','activity','walks']},freshness=dict(records=dict(steps=dict(observed_at=stamp(-15)),activity=dict(observed_at=stamp(-15))),device=dict(last_sync_at=stamp(-20))),tip='今天按自己的节奏安排训练。')
payload=dict(marker='PINE_DESIGN_SAMPLE_DATA_V1',catalog=dict(exercises=ex,templates=[dict(template=t,version=1) for t in programs]),home=home,records=records,brief=dict(date=day(0),period='morning',title='早间观察',status='ready',generated_at=stamp(-20),sentences=[dict(text='最近一晚睡眠接近期望时长，恢复指标与近期记录相近。'),dict(text='今天的训练已经记录，晚上按平时的节奏散步即可。')]),archive=dict(training=[],exercises=[dict(date=day(-1),time='18:45',name='WALKING',duration_minutes=28,calories=115)]))
raw=json.dumps(payload,ensure_ascii=False,separators=(',',':'))
out=ROOT/'ios/App/NativeDesignFixtures.swift'
out.write_text('''// Synthetic, read-only design previews. Excluded from every Release binary.
#if DEBUG && targetEnvironment(simulator)
import Foundation

enum NativeDesignFixtures {
    private static let raw = #"""
'''+raw+'''
"""#
    static let document = (try? JSONValue.read(Data(raw.utf8))) ?? .null
    static var archive: JSONValue { document["archive"] }
    static var cache: NativeCacheState {
        var cache = NativeCacheState()
        cache.catalog = document["catalog"]; cache.home = document["home"]; cache.brief = document["brief"]
        cache.records = Dictionary(uniqueKeysWithValues: document["records"].array.map { let row = NativeRecord(remote: $0); return (row.id, row) })
        return cache
    }
}
#endif
''')
print('Generated synthetic, simulator-only design fixtures.')
