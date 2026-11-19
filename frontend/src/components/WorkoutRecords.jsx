import { useEffect, useState } from 'react'
import { getWorkoutArchive } from '../api/client'
import { clockText, elapsedSeconds, localDateKey, weightUnitLabel } from '../training/strength'
import { workProgress, isPosture } from '../training/ux'
import HealthIcon from './HealthIcon'
import Modal from './Modal'

const activityLabels = {Walk:'步行',WALKING:'步行',Strength:'力量训练',STRENGTH_TRAINING:'力量训练',Run:'跑步',RUNNING:'跑步',Cycling:'骑行',CYCLING:'骑行',BIKING:'骑行',Swimming:'游泳',SWIMMING:'游泳',Yoga:'瑜伽',YOGA:'瑜伽',HIKING:'徒步',WORKOUT:'运动'}
const activityName = name => activityLabels[name] || (/^[A-Z0-9_]+$/.test(name) ? '运动' : name) || '运动'
export default function WorkoutRecords({store,onOpenTraining,onStart,visible=true,active=true}) {
  const [archive,setArchive]=useState(null),[failed,setFailed]=useState(false),[attempt,setAttempt]=useState(0)
  const [detail,setDetail]=useState(null),[kind,setKind]=useState('all'),[query,setQuery]=useState(''),[month,setMonth]=useState(''),[limit,setLimit]=useState(30)
  useEffect(()=>{if(!active)return;const controller=new AbortController();setFailed(false);getWorkoutArchive(controller.signal).then(d=>{if(!controller.signal.aborted)setArchive(d)}).catch(()=>{if(!controller.signal.aborted)setFailed(true)});return()=>controller.abort()},[active,attempt])
  useEffect(()=>setLimit(30),[kind,query,month])
  const records=[
    ...store.history.filter(r=>r.session.status==='completed').map(({session,dirty})=>{
      const p=workProgress(session),posture=isPosture(session)
      return {key:session.id,date:localDateKey(session.started_at,session.timezone),time:new Date(session.started_at).toLocaleTimeString('zh-CN',{timeZone:session.timezone,hour:'2-digit',minute:'2-digit',hour12:false}),title:session.title,kind:posture?'posture':'strength',
        search:session.exercises.map(m=>m.name).join(' '),detail:`${clockText(elapsedSeconds(session))} · ${p.done}/${p.planned} ${posture?'练习组':'工作组'}${p.warmup?` · 热身 ${p.warmup} 组`:''}`,note:dirty?'本机已保存 · 待同步':'',open:()=>onOpenTraining(session.id)}
    }),
    ...(archive?.training||[]).map((r,i)=>({key:`archive:${i}`,date:r.datestr,time:r.time||'',title:r.title||'力量训练',kind:'strength',search:r.movements.map(m=>m.name).join(' '),detail:`${r.duration_minutes||0} 分钟 · ${r.movements.length} 动作`,open:()=>setDetail({type:'archive',value:r})})),
    ...(archive?.exercises||[]).map((r,i)=>({key:`activity:${i}`,date:r.date,time:r.time||'',title:activityName(r.name),kind:/walk|步行|散步/i.test(r.name)?'walk':'other',detail:[`${r.duration_minutes} 分钟`,r.calories>0&&`${Math.round(r.calories)} 千卡`].filter(Boolean).join(' · '),open:()=>setDetail({type:'activity',value:r})})),
  ].sort((a,b)=>(b.date||'').localeCompare(a.date||'')||b.time.localeCompare(a.time))
  const terms=query.trim().toLowerCase().split(/\s+/).filter(Boolean)
  const filtered=records.filter(r=>(kind==='all'||r.kind===kind)&&(!month||r.date?.startsWith(month))&&terms.every(t=>`${r.title} ${r.search||''}`.toLowerCase().includes(t)))
  const groups=new Map();for(const r of filtered.slice(0,limit)){if(!groups.has(r.date))groups.set(r.date,[]);groups.get(r.date).push(r)}
  const labels={strength:'力量',posture:'体态',walk:'散步',other:'运动'},today=localDateKey(new Date().toISOString())
  return <section className="strength-app st-records" aria-label="运动记录" hidden={!visible}>
    <div className="st-record-filters"><div className="st-filter-chips" aria-label="记录类型">{[['all','全部'],['strength','力量'],['posture','体态'],['walk','散步']].map(([id,label])=><button key={id} aria-pressed={kind===id} onClick={()=>setKind(id)}>{label}</button>)}</div>
      <input className="st-search" type="search" aria-label="搜索运动记录" placeholder="搜索动作或训练名称" value={query} onChange={e=>setQuery(e.target.value)}/>
      <details className="st-record-date"><summary>按月份查找{month&&` · ${month}`}</summary><label>月份<input type="month" aria-label="记录月份" value={month} onChange={e=>setMonth(e.target.value)}/></label></details>
    </div>
    {(failed||store.error)&&<p className="st-muted" role="status">部分记录暂未更新。<button className="st-text-button" onClick={()=>{store.refresh();setAttempt(n=>n+1)}}>重试</button></p>}
    {!filtered.length&&<div className="st-empty" role="status">{!store.ready||(!archive&&!failed)?'正在读取记录…':records.length?'没有匹配的记录。':'完成训练后，记录会显示在这里。'}{records.length?<button className="st-text-button" onClick={()=>{setKind('all');setQuery('');setMonth('')}}>清除筛选</button>:<button className="st-primary" onClick={onStart}>开始训练</button>}</div>}
    <div className="st-history-list">{[...groups].map(([date,day])=><section key={date} className="card p-4"><h2 className="text-sm font-semibold mb-2">{date===today?'今日':date}</h2>{day.map(r=><article key={r.key} className="st-history-card"><button type="button" className="st-history-open" onClick={r.open}><span className="st-record-title"><small className={`st-record-kind ${r.kind}`}>{labels[r.kind]}</small><strong>{r.title}</strong><HealthIcon name="arrow" size={13}/></span><small className="st-muted">{[r.time,r.detail].filter(Boolean).join(' · ')}</small>{r.note&&<small className="st-muted">{r.note}</small>}</button></article>)}</section>)}</div>
    {filtered.length>limit&&<button className="st-secondary st-wide" onClick={()=>setLimit(n=>n+30)}>显示更早记录</button>}
    {detail&&<Modal title={detail.type==='activity'?activityName(detail.value.name):detail.value.title||'力量训练'} onClose={()=>setDetail(null)}>
      <p className="st-muted">{detail.value.datestr||detail.value.date} · {detail.value.time} · {detail.value.duration_minutes||0} 分钟</p>
      {detail.type==='activity'?<><p className="st-lead">{detail.value.calories>0?`${Math.round(detail.value.calories)} 千卡`:''}</p><p className="st-muted">Google Health 活动记录 · 时长按设备记录显示</p></>:<>{detail.value.movements.map((m,i)=><div className="st-history-detail" key={i}><strong>{m.name}</strong>{m.sets.map((s,j)=><p key={j}><span>第 {j+1} 组</span><b>{s.selfWeight?'自重':`${s.weight} ${weightUnitLabel(s.unit)}`} × {s.reps} 次</b></p>)}</div>)}<p className="st-muted">历史训练档案</p></>}
    </Modal>}
  </section>
}
