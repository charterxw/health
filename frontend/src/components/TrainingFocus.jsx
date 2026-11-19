import {useState} from 'react'
import {weeklyMuscles,muscleGroups} from '../training/muscles'
const labels=['侧平举','肩部推举','肩后束','二头直接','三头直接','胸部','背部','下肢']
function category(m,catalog){const e=catalog.find(e=>e.id===m.exercise_id||e.id===m.id)||m,n=e.name||m.name||'';if(/侧平举/.test(n))return 0;if(/推肩|肩推|肩上推举/.test(n))return 1;if(/反向飞鸟|后束/.test(n))return 2;const primary=muscleGroups(m,e).primary;if(primary.includes('biceps')||/弯举/.test(n))return 3;if(primary.includes('triceps')||/下压|臂屈伸/.test(n))return 4;if(primary.includes('chest'))return 5;if(primary.includes('upper-back'))return 6;if(primary.some(g=>['gluteal','quadriceps','hamstring'].includes(g)))return 7;return -1}
export default function TrainingFocus({history=[],catalog=[],round}){
 const [period,setPeriod]=useState('week'),counts=labels.map(()=>0),targets=labels.map(()=>0)
 const window=weeklyMuscles(history,catalog)
 if(period==='round'&&round){for(const slot of round.slots||[])for(const m of slot.exercises||[]){const i=category(m,catalog);if(i<0)continue;targets[i]+=m.target;counts[i]+=m.target-((slot.remaining||[]).find(r=>r.exercise_id===m.exercise_id)?.target||0)}}
 else for(const {session:s} of history){if(s.status!=='completed')continue;const day=new Intl.DateTimeFormat('en-CA',{timeZone:s.timezone||'America/New_York'}).format(new Date(s.started_at));if(day<window.start||day>window.end)continue;for(const m of s.exercises){if(m.training_type==='mobility')continue;const i=category(m,catalog);if(i>=0)counts[i]+=m.sets.filter(s=>s.completed_at&&!s.warmup&&Number(s.reps)>0).length}}
 return <div className="st-focus"><div className="st-filter-chips">{[['week','本周直接组'],['round','本轮方案']].map(([id,text])=><button key={id} aria-pressed={period===id} disabled={id==='round'&&!round} onClick={()=>setPeriod(id)}>{text}</button>)}</div><div className="st-goal-categories">{labels.map((label,i)=><div key={label}><span>{label}</span><b>{counts[i]}{period==='round'?` / ${targets[i]}`:''}</b></div>)}</div></div>
}
