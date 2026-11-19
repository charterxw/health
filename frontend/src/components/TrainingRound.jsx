import { useEffect, useState } from 'react'
import { getHome, linkHomePlan, nextHomeRound } from '../api/client'
import Modal from './Modal'
import HealthIcon from './HealthIcon'
import './home.css'
import { readTrainingPlan } from '../training/planCache'

const complete = slot => slot.completed || slot.done >= slot.target
const stateText = slot => slot.completion_confirmed ? '已完成 · 按当日模板' : complete(slot) ? '已完成' : slot.done ? '待继续' : '待练'

function Rows({rows}) { return <div className="home-detail-rows">{rows.map(([label,value],i)=><div key={i}><span>{label}</span><span>{value}</span></div>)}</div> }

export default function TrainingRound({active,onTraining,onData,changed}) {
  const [open,setOpen]=useState(false),[data,setData]=useState(readTrainingPlan),[error,setError]=useState(''),[busy,setBusy]=useState(false),[attempt,setAttempt]=useState(0)
  useEffect(()=>{const update=()=>{const cached=readTrainingPlan();if(cached)setData(cached)};window.addEventListener('health-training-plan',update);return()=>window.removeEventListener('health-training-plan',update)},[])
  useEffect(()=>{if(data)onData?.(data)},[data,onData])
  useEffect(()=>{if(!active)setOpen(false)},[active])
  useEffect(()=>{
    if(!open&&!active)return
    const controller=new AbortController()
    setError('')
    getHome(controller.signal).then(value=>{if(!controller.signal.aborted){setData(value);onData?.(value)}}).catch(e=>{if(!controller.signal.aborted)setError(e.message||'暂时无法读取方案')})
    return()=>controller.abort()
  },[open,active,attempt,changed,onData])
  async function mutate(call) {
    if(busy)return
    setBusy(true);setError('')
    try{const value=await call();setData(value);onData?.(value)}catch(e){setError(e.message||'保存失败，请重试')}finally{setBusy(false)}
  }
  const weekDays=data?.days.filter(x=>x.date<=data.date&&x.sets>0).length||0
  const launch=()=>{setOpen(false);onTraining?.(data.action)}
  const actionLabel=data?.action.session_id?'继续正在进行的训练':data?.plan?.next?`查看下次训练 · ${data.plan.next.short}`:'查看训练模板'
  return <>
    <section className="st-current-plan" aria-label="当前训练安排"><div className="home-between"><h2>{data?.plan?.current?.optional?'当前安排 · 可选':data?.plan&&!data.plan.next?'本轮已完成':'当前安排'}</h2>{data?.plan&&<button className="st-text-button" aria-label="查看本轮进度" onClick={()=>setOpen(true)}>{data.plan.done} / {data.plan.target} 工作组 ›</button>}</div>{data?.plan?(()=>{const slots=data.plan.slots||[],index=Math.max(0,slots.findIndex(s=>s.template_id===data.plan.next?.template_id)),pair=data.plan.current?.slots||slots.slice(Math.floor(index/2)*2,Math.floor(index/2)*2+2);return pair.map((slot,i)=><div key={slot.template_id} className="st-current-slot"><span><strong>{slot.name}</strong><small>{slot.done}/{slot.target} 工作组 · {stateText(slot)}</small></span><button className={i===0?'st-primary':'st-secondary'} disabled={complete(slot)} onClick={()=>onTraining?.({template_id:slot.template_id,remaining:slot.remaining})}>{complete(slot)?'已完成':slot.done?'继续':'开始'}</button></div>)})():<div className="st-plan-placeholder" aria-label="正在读取安排"><span/><span/></div>}</section>
    {open&&<Modal title="本轮进度" onClose={()=>setOpen(false)}><div className="home-dialog">
      {error&&<p className="home-note" role="alert">{error}<button className="home-text" onClick={()=>setAttempt(n=>n+1)}>重试</button></p>}
      {!data&&!error&&<p className="home-note" role="status">正在读取方案…</p>}
      {data&&<><p className="home-lead">{data.plan?`${data.plan.done} / ${data.plan.target} 组`:'尚未设置方案'}</p><p className="home-note">本周练过 {weekDays} 天。本轮可以跨周，可选 E 不影响主训练进度。</p>{data.plan?.schedule?data.plan.schedule.map(day=><div key={day.letter} className="st-schedule-day"><h3>第{day.day}天 · {day.letter}{day.optional?' · 可选':''}</h3><Rows rows={day.slots.map(s=>[s.name,`${s.done} / ${s.target} 组${complete(s)?' · 已完成':''}`])}/></div>):<Rows rows={(data.plan?.slots||[]).map(s=>[s.name,s.completion_confirmed?'已完成 · 按当日模板':`${s.done} / ${s.target} 组${complete(s)?' · 已完成':''}`])}/>}<button className="home-primary" onClick={launch}>{actionLabel}</button><details className="home-plan-tools"><summary>关联补练与开始下一轮</summary><p className="home-note">选择训练记录与对应模板，同一条补练可关联多个模板，匹配组数依次分配。</p><form className="home-form" onSubmit={e=>{e.preventDefault();const f=new e.currentTarget.ownerDocument.defaultView.FormData(e.currentTarget);mutate(()=>linkHomePlan({session_id:f.get('session'),slot:Number(f.get('slot')),remove:e.nativeEvent.submitter?.value==='remove'}))}}><label>训练记录<select name="session" required>{data.days.flatMap(r=>r.sessions||[]).filter((s,i,all)=>all.findIndex(x=>x.id===s.id)===i).map(s=><option value={s.id} key={s.id}>{s.title}</option>)}</select></label><label>归属模板<select name="slot">{data.plan?.slots.map((s,i)=><option value={i} key={i}>{s.name}</option>)}</select></label><button className="home-primary" disabled={busy}>关联这次补练</button><button className="home-text" type="submit" value="remove" disabled={busy}>解除所选关联</button></form><button className="home-text" disabled={busy} onClick={()=>{if(window.confirm('结束当前轮次并开始下一轮？未完成部分会保留在上一轮。'))mutate(nextHomeRound)}}>结束本轮，开始下一轮</button></details></>}
    </div></Modal>}
  </>
}
