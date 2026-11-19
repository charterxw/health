import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import Modal from './Modal'
import HealthIcon from './HealthIcon'
import { getHome, refreshHome, saveHomeGoals, saveHomeStepGoal, saveHomeFeedback, saveHomeWalk, getHomeBrief, requestHomeBrief } from '../api/client'
import './dashboard.css'
import './home.css'
import { ageText, recordClock, freshnessSummary } from '../dataFreshness'
import { watchHomeLayout } from '../training/homeLayout'

const useBrowserLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect

export const num = v => v == null ? '—' : Number(v).toLocaleString('zh-CN', { maximumFractionDigits: 1 })
export function latestRead(sources) {
  return Object.values(sources || {}).map(source => source?.fetched_at)
    .filter(stamp => stamp && Number.isFinite(Date.parse(stamp)))
    .sort((a, b) => Date.parse(b) - Date.parse(a))[0] || null
}
export function retainBrief(previous, next) {
  return previous?.status === 'ready' && previous.date === next.date && previous.period === next.period && next.status !== 'ready'
    ? previous : next
}
const dateLabel = date => date?.slice(5).replace('-', '/') || '—'
const NAMES = ['一', '二', '三', '四', '五', '六', '日']
const COLORS = ['var(--home-activity)', 'var(--home-strength)', 'var(--home-posture)']
export function clock(time, timezone, offset) {
  if (!time) return '—'
  if (offset && /^-?\d+(\.\d+)?s$/.test(offset)) return new Date(Date.parse(time)+parseFloat(offset)*1000).toISOString().slice(11,16)
  return new Date(time).toLocaleTimeString('zh-CN', { timeZone: timezone, hour:'2-digit', minute:'2-digit', hour12:false })
}
export function rhythm(sleeps, timezone) {
  const seen = new Set()
  const values = sleeps.filter(s=>!s.is_nap && s.start_time && !seen.has(s.date) && seen.add(s.date)).slice(0,7).map(s=>{
    const value=clock(s.start_time,timezone,s.start_utc_offset); let n=Number(value.slice(0,2))*60+Number(value.slice(3)); return n<720?n+1440:n
  }).filter(Number.isFinite)
  if(values.length<4)return null
  const avg=values.reduce((s,x)=>s+x,0)/values.length
  const deviation=Math.round(values.reduce((s,x)=>s+Math.abs(x-avg),0)/values.length)
  return {deviation,label:deviation<=30?'稳定':'有波动'}
}
export function weightWeeks(weights) {
  const groups=new Map()
  for(const w of weights){const day=new Date(`${w.date}T12:00:00Z`);day.setUTCDate(day.getUTCDate()-(day.getUTCDay()+6)%7);const key=day.toISOString().slice(0,10);if(!groups.has(key))groups.set(key,[]);groups.get(key).push(w.kg)}
  return [...groups].sort((a,b)=>b[0].localeCompare(a[0])).map(([date,values])=>({date,count:values.length,kg:values.reduce((a,b)=>a+b,0)/values.length}))
}
function Ring({values}) {return <svg className="home-rings" viewBox="0 0 48 48" aria-hidden="true">{values.map((ratio,i)=>{const r=21-i*6,c=2*Math.PI*r;return <g key={i}><circle cx="24" cy="24" r={r} fill="none" stroke={ratio==null?'var(--home-rest)':'var(--home-track)'} strokeWidth="3.6"/>{ratio>0&&<circle cx="24" cy="24" r={r} fill="none" stroke={COLORS[i]} strokeWidth="3.6" strokeLinecap="round" strokeDasharray={`${Math.min(1,ratio)*c} ${c}`}/>}</g>})}</svg>}
function Rows({rows}){return <div className="home-detail-rows">{rows.map(([label,value],i)=><div key={i}><span>{label}</span><span>{value}</span></div>)}</div>}
export function briefPreview(sentences, fallback) {
  if (!sentences?.length) return [fallback]
  const observation = sentences.find(s=>s.evidence_ids?.includes('recovery-state')) || sentences.find(s=>s.evidence_ids?.some(id=>id.includes('trend')||id==='recovery-pattern')) || sentences[0]
  const guidance = sentences.findLast(s=>s.evidence_ids?.includes('guidance')) || sentences.at(-1)
  return [...new Set([observation.text, guidance.text])]
}
function StepGoalEditor({goal,onSave,busy}) {
  const [target,setTarget]=useState(goal?.target??'')
  return <form className="home-form home-step-goal-form" onSubmit={e=>{e.preventDefault();onSave({target:Number(target)})}}><label>每日步数目标<input type="number" inputMode="numeric" min="1000" max="50000" step="1" required value={target} onChange={e=>setTarget(e.target.value)}/></label><p className="home-note">{goal?.basis} 保存后立即生效，之后不会随数据更新自动改变。</p><button className="home-primary" disabled={busy}>保存步数目标</button></form>
}
function GoalEditor({data,onSave,busy}) {
  const [goals,setGoals]=useState(data.next_goals||data.goals)
  const fields=[['dailyActivity','日常活动 · 每日千卡',3000],['weeklyActivity','日常活动 · 每周千卡',21000],['weeklyStrength','力量训练 · 每周天数',7],['weeklyPosture','体态练习 · 每周天数',7]]
  return <form className="home-form" onSubmit={e=>{e.preventDefault();onSave(Object.fromEntries(fields.map(([key])=>[key,Number(goals[key])])) )}}><p className="home-note">{dateLabel(data.next_effective)} 起生效，保留本周与过去的完成记录。</p>{fields.map(([key,label,max])=><label key={key}>{label}<input type="number" inputMode="numeric" min="1" max={max} required value={goals[key]} onChange={e=>setGoals({...goals,[key]:e.target.value})}/></label>)}<button className="home-primary" disabled={busy}>保存下周目标</button></form>
}
function Feelings({data,onSave,busy}) {
  const [draft,setDraft]=useState({energy:data.feedback.energy||null,fatigue:data.feedback.fatigue||null})
  return <div className="home-form"><p className="home-note">可只记一项，用于调整今天的运动建议。</p>{[['energy','精神状态',['充沛','一般','困倦']],['fatigue','身体疲劳',['轻','中','重']]].map(([key,title,options])=><fieldset key={key}><legend>{title}</legend><div className="home-choices">{options.map(o=><button type="button" key={o} aria-pressed={draft[key]===o} onClick={()=>setDraft({...draft,[key]:draft[key]===o?null:o})}>{o}</button>)}</div></fieldset>)}<button className="home-primary" disabled={busy} onClick={()=>onSave(draft)}>保存今天的感受</button><button className="home-text" disabled={busy} onClick={()=>onSave({energy:null,fatigue:null})}>清除今天的记录</button></div>
}
function WalkEditor({walk,timezone,onSave,busy}) {
  const [start,setStart]=useState(clock(walk.start,timezone)),[end,setEnd]=useState(clock(walk.end,timezone)),[error,setError]=useState('')
  const save=ignored=>{const a=start.split(':').map(Number),b=end.split(':').map(Number),original=clock(walk.start,timezone).split(':').map(Number);const base=Date.parse(walk.start)-(original[0]*60+original[1])*60000;if(b[0]*60+b[1]<=a[0]*60+a[1]){setError('结束时间应晚于开始时间');return}onSave({id:walk.id,start:new Date(base+(a[0]*60+a[1])*60000).toISOString(),end:new Date(base+(b[0]*60+b[1])*60000).toISOString(),ignored})}
  return <div className="home-form"><label>开始时间<input type="time" value={start} onChange={e=>setStart(e.target.value)} required/></label><label>结束时间<input type="time" value={end} onChange={e=>setEnd(e.target.value)} required/></label>{error&&<p role="alert">{error}</p>}<p className="home-note">只调整本 App 的活动记录，全天步数与热量保留原始测量。</p><button className="home-primary" disabled={busy||!start||!end} onClick={()=>save(false)}>保存时间</button><button className="home-text" disabled={busy||!start||!end} onClick={()=>save(!walk.ignored)}>{walk.ignored?'恢复识别记录':'忽略这条识别记录'}</button></div>
}

export default function Dashboard({active=true,onTraining,onSleep}) {
  const [data,setData]=useState(null),[selected,setSelected]=useState(null),[detail,setDetail]=useState(null),[walk,setWalk]=useState(null)
  const [busy,setBusy]=useState(false),[refreshing,setRefreshing]=useState(false),[error,setError]=useState(''),[attempt,setAttempt]=useState(0)
  const [brief,setBrief]=useState(null),[briefAttempt,setBriefAttempt]=useState(0)
  const requestedBrief=useRef(0)
  const [clockNow,setClockNow]=useState(()=>Date.now())
  const layoutRef=useRef(null)
  useBrowserLayoutEffect(()=>active&&data?watchHomeLayout(layoutRef.current):undefined,[active,Boolean(data)])
  useEffect(()=>{
    if(!active)return
    setClockNow(Date.now())
    const timer=setInterval(()=>setClockNow(Date.now()),60000)
    return()=>clearInterval(timer)
  },[active])

  useEffect(()=>{
    if(!active){setDetail(null);return}
    const controller=new AbortController();setRefreshing(true)
    const apply=value=>{if(!controller.signal.aborted){setData(value);setSelected(old=>value.days.some(d=>d.date===old)?old:value.date)}}
    // Serial cache read prevents a late old response overwriting a fresh refresh.
    getHome(controller.signal).then(apply).catch(()=>{}).then(()=>{if(controller.signal.aborted)return;return refreshHome(controller.signal).then(value=>{apply(value);setError(value.refresh_failed?.length?'部分数据待更新':'')})}).catch(err=>{if(!controller.signal.aborted)setError(err.status===409?'连接 Google Health 后更新活动数据':'暂时无法更新，请重试')}).finally(()=>{if(!controller.signal.aborted)setRefreshing(false)})
    return ()=>controller.abort()
  },[active,attempt])
  useEffect(()=>{if(!active)return;const refresh=()=>{if(document.visibilityState!=='hidden')setAttempt(n=>n+1)};window.addEventListener('online',refresh);document.addEventListener('visibilitychange',refresh);const timer=setInterval(refresh,5*60000);return()=>{window.removeEventListener('online',refresh);document.removeEventListener('visibilitychange',refresh);clearInterval(timer)}},[active])
  useEffect(()=>{
    if(!active||!data)return
    const controller=new AbortController();let timer;let polls=0
    const force=requestedBrief.current!==briefAttempt;requestedBrief.current=briefAttempt
    const accept=report=>{if(controller.signal.aborted)return;if(Array.isArray(report.sentences))setBrief(old=>retainBrief(old,report));if(report.status==='pending'&&polls++<85)timer=setTimeout(()=>getHomeBrief(controller.signal).then(accept).catch(()=>{}),2000)}
    getHomeBrief(controller.signal).then(report=>{if(controller.signal.aborted)return;if(force||report.status==='idle'||report.status==='error')return requestHomeBrief(controller.signal,force).then(accept);accept(report)}).catch(()=>{})
    return()=>{controller.abort();clearTimeout(timer)}
  },[active,data?.date,data?.sources.metrics.fetched_at,data?.sources.sleep?.fetched_at,data?.feedback.energy,data?.feedback.fatigue,briefAttempt])
  async function mutate(call,close=true){if(busy)return;setBusy(true);setError('');try{setData(await call());if(close)setDetail(null)}catch(e){setError(e.message||'保存失败，请重试')}finally{setBusy(false)}}
  if(!data)return <div className="home-dashboard"><p className="home-note">{error||'正在读取今天的安排…'}</p>{error&&<button className="home-text" onClick={()=>setAttempt(n=>n+1)}>重试</button>}</div>
  const d=data.days.find(x=>x.date===selected)||data.days.find(x=>x.date===data.date),isToday=d.date===data.date
  const currentWeek=data.days.filter(x=>x.date<=data.date),energies=currentWeek.filter(x=>x.activity!=null)
  const weekEnergy=energies.length?energies.reduce((s,x)=>s+x.activity,0):null,weekDays=currentWeek.filter(x=>x.sets>0).length,postureDays=currentWeek.filter(x=>x.posture).length
  const score=data.recovery,sleep=data.sleep,sleepMinutes=sleep?.minutes_asleep||(data.today.sleep_hours>0?Math.round(data.today.sleep_hours*60):null),schedule=rhythm(data.sleeps,data.timezone)
  const next=data.plan?.next
  const actionLabel=data.action.session_id?'继续正在进行的训练':next?(data.days.find(x=>x.date===data.date)?.strength_planned?`${next.short} · 剩余 ${next.target-next.done} 组`:`下次训练 · ${next.short}`):'查看训练记录'
  const feelings=[data.feedback.energy,data.feedback.fatigue&&`疲劳${data.feedback.fatigue}`].filter(Boolean).join(' · ')
  const start=data.days[0].date,end=data.days[6].date,stamp=latestRead(data.sources)
  const freshness=data.freshness||{},fresh=freshnessSummary(freshness,data.timezone,clockNow)
  const observedText=value=>value?`${recordClock(value,data.timezone,clockNow)} · ${ageText(value,clockNow)||'—'}`:'—'
  const launch=()=>{setDetail(null);onTraining?.(data.action)}
  const localHour=Number(new Intl.DateTimeFormat('en-GB',{timeZone:data.timezone,hour:'2-digit',hourCycle:'h23'}).format(new Date()))
  const period=localHour>=18?'evening':'morning'
  const currentBrief=brief?.date===data.date&&brief.period===period?brief:null
  const briefReady=currentBrief?.status==='ready'&&currentBrief.sentences.length>0
  const briefTitle=period==='evening'?'晚间观察':'早间观察'
  const fallback=period==='evening'?'今晚按平时的时间准备休息，结合今天的体感安排恢复。':data.tip
  const briefText=briefReady?currentBrief.sentences.map(s=>s.text).join(''):fallback
  const preview=briefPreview(briefReady?currentBrief.sentences:null,fallback)
  const stepTarget=data.step_goal?.target
  const stepProgress=data.today.steps!=null&&stepTarget?Math.max(0,Math.min(100,data.today.steps/stepTarget*100)):null
  const title={advice:briefTitle,recovery:'恢复指数',sleep:'睡眠与作息',rhythm:'作息规律',steps:'今日步数',activity:'日常活动',training:'力量训练',posture:'体态练习',goals:'下周目标',feedback:'今天的感受',sync:'数据与同步',walk:'调整散步记录'}[detail]
  const show=key=>setDetail(key)
  return <div className="home-dashboard" ref={layoutRef}>
    <header className="home-heading"><span>{new Date(`${data.date}T12:00:00`).toLocaleDateString('zh-CN',{month:'long',day:'numeric',weekday:'long'})}</span><button aria-busy={refreshing} onClick={()=>show('sync')}><span className="home-sync-status" role="status" aria-live="polite">{refreshing?<><i className="home-sync-spinner" aria-hidden="true"/>正在同步…</>:fresh?.label||(stamp?`最近读取 ${clock(stamp,data.timezone)}`:'尚未读取')}</span></button></header>
    <section className="home-panel home-tip"><div className="home-between"><span className="home-brief-label"><i/>{briefTitle}</span><HealthIcon name="arrow" size={13}/></div><button className="home-brief-text" onClick={()=>show('advice')} aria-label={`${briefTitle}，查看分析依据`} aria-busy={currentBrief?.status==='pending'}>{preview.map((text,i)=><span key={i}>{text}</span>)}</button></section>
    <div className="home-tiles">
      <section className="home-panel home-tile home-recovery" data-state={score.score==null?'pending':score.score>=65?'steady':'adjust'}><button className="home-tile-main" onClick={()=>show('recovery')} aria-label={`恢复指数 ${score.score??'待更新'}，查看依据`}><span className="home-tile-label">恢复指数<HealthIcon name="arrow" size={12}/></span><strong>{score.score??'—'}<small> / 100</small></strong><span className="home-recovery-state"><i/>{score.label}</span></button></section>
      <section className="home-panel home-tile home-steps"><button className="home-tile-main" onClick={()=>show('steps')} aria-label={`今日步数 ${num(data.today.steps)}，目标 ${num(stepTarget)} 步`}><span className="home-tile-label">今日步数<HealthIcon name="arrow" size={12}/></span><strong>{num(data.today.steps)}</strong><small className="home-step-target">/ {num(stepTarget)} 步</small><span className="home-step-track" aria-hidden="true"><span style={{width:`${stepProgress??0}%`}}/></span></button></section>
    </div>
    <section className="home-panel home-goals"><div className="home-between"><h2>活动与训练</h2><span className="home-week-range">{dateLabel(start)}–{dateLabel(end)}<button onClick={()=>show('goals')} aria-label="调整下周目标"><HealthIcon name="settings" size={16}/></button></span></div>
      <div className="home-days">{data.days.map((day,i)=>{const ratios=[day.activity==null?null:day.activity/day.goals.dailyActivity,day.strength_planned&&day.target?day.sets/day.target:null,day.posture_planned||day.posture?Number(day.posture):null];return <button key={day.date} onClick={()=>setSelected(day.date)} aria-pressed={day.date===d.date} aria-label={`${dateLabel(day.date)}，${day.short}，日常活动${num(day.activity)}千卡，力量${day.sets}/${day.target}组，体态${day.posture?'完成':day.posture_planned?'待完成':'未安排'}`}><span className="home-day-name">{day.date===data.date?'今':NAMES[i]}</span><Ring values={ratios}/><small>{day.short}</small></button>})}</div>
      <table className="home-table"><colgroup><col/><col/><col/></colgroup><thead><tr><th>目标</th><th>{isToday?'今日':`周${NAMES[data.days.indexOf(d)]} · ${Number(d.date.slice(-2))}日`}</th><th>本周</th></tr></thead><tbody aria-live="polite">
        <tr><th><button onClick={()=>show('activity')}><i style={{background:COLORS[0]}}/><span>日常活动</span></button></th><td><button onClick={()=>show('activity')}><strong>{num(d.activity)}</strong><small> / {num(d.goals.dailyActivity)}</small></button></td><td><strong>{num(weekEnergy)}</strong><small> / {num(data.goals.weeklyActivity)}</small></td></tr>
        <tr><th><button onClick={()=>show('training')}><i style={{background:COLORS[1]}}/>力量训练</button></th><td><button onClick={()=>show('training')}>{d.strength_planned||d.strength_optional?<><strong>{d.sets}</strong><small> / {d.target} 组{d.strength_optional?' · 可选':''}</small></>:<small>休息日</small>}</button></td><td><strong>{weekDays}</strong><small> / {data.goals.weeklyStrength} 天</small></td></tr>
        <tr><th><button onClick={()=>show('posture')}><i style={{background:COLORS[2]}}/>体态练习</button></th><td><button onClick={()=>show('posture')}>{d.posture_planned||d.posture?<><strong>{Number(d.posture)}</strong><small> / 1 次</small></>:<small>未安排</small>}</button></td><td><strong>{postureDays}</strong><small> / {data.goals.weeklyPosture} 天</small></td></tr>
      </tbody></table><div className="home-footer"><button className="home-feedback" onClick={()=>show('feedback')}><span>{feelings||'今天感觉如何？'}</span><small>{feelings?'修改':'可选记录'} ›</small></button></div>
    </section>
    {detail&&<Modal title={title} onClose={()=>setDetail(null)}><div className="home-dialog">{error&&<p role="alert" className="home-note">{error}</p>}
      {detail==='goals'&&<GoalEditor data={data} busy={busy} onSave={v=>mutate(()=>saveHomeGoals(v))}/>}
      {detail==='feedback'&&<Feelings data={data} busy={busy} onSave={v=>mutate(()=>saveHomeFeedback(v))}/>}
      {detail==='advice'&&<><p className="home-lead">{briefText}</p><Rows rows={[[`恢复 ${score.score??'—'}`,score.label],['昨夜睡眠',sleepMinutes?`${Math.floor(sleepMinutes/60)}小时${sleepMinutes%60}分`:'待更新'],['HRV',`${num(data.today.hrv||null)} ms · 平时 ${num(score.hrv_baseline)}`],['静息心率',`${num(data.today.resting_hr||null)} 次/分 · 平时 ${num(score.rhr_baseline)}`],['今天感受',feelings||'未填写']]}/><button className="home-text" onClick={()=>setBriefAttempt(v=>v+1)} disabled={currentBrief?.status==='pending'}>{currentBrief?.status==='pending'?'AI 分析中…':'重新分析'}</button><p className="home-note">{briefReady?`AI 摘要 · ${clock(currentBrief.generated_at,data.timezone)} 更新`:'结合已同步记录展示今日观察。'}</p></>}
      {detail==='recovery'&&<><div className="home-recovery-detail"><strong>{score.score??'—'}<small> / 100</small></strong><span>{score.label}</span></div><p className="home-note">结合昨夜睡眠时长、HRV和静息心率相对个人基线计算，用于观察恢复状态。{score.score==null?'等待当日指标及足够的个人基线记录。':'指数不代表肌肉修复比例，训练安排仍结合今天的体感。'}</p>{score.caution&&<p className="home-note">近期有几次恢复信号偏弱，留意热身和身体感受。</p>}<Rows rows={ [['昨夜睡眠',sleepMinutes?`${Math.floor(sleepMinutes/60)}小时${sleepMinutes%60}分`:'待更新'],['HRV',`${num(data.today.hrv||null)} ms · 平时 ${num(score.hrv_baseline)}`],['静息心率',`${num(data.today.resting_hr||null)} 次/分 · 平时 ${num(score.rhr_baseline)}`],['今天感受',feelings||'未填写']] }/><button className="home-text" onClick={()=>show('sleep')}>查看睡眠与作息 ›</button><button className="home-text" onClick={()=>show('advice')}>查看今日观察 ›</button></>}
      {(detail==='sleep'||detail==='rhythm')&&<><p className="home-lead">{schedule?`入睡时间平均波动约 ${schedule.deviation} 分钟`:'近期睡眠记录'}</p><Rows rows={data.sleeps.filter(s=>!s.is_nap).slice(0,7).map(s=>[dateLabel(s.date),`${clock(s.start_time,data.timezone,s.start_utc_offset)} → ${clock(s.end_time,data.timezone,s.end_utc_offset)}`])}/><button className="home-primary" onClick={()=>{setDetail(null);onSleep?.()}}>查看睡眠趋势</button></>}
      {detail==='steps'&&<><p className="home-lead">{num(data.today.steps)} / {num(stepTarget)} 步</p><StepGoalEditor goal={data.step_goal} busy={busy} onSave={v=>mutate(()=>saveHomeStepGoal(v))}/><h3 className="home-detail-heading">最近步数</h3><Rows rows={data.metrics.slice(0,7).map(r=>[dateLabel(r.date),`${num(r.steps)} 步`])}/><h3>散步记录</h3>{data.walks.slice(0,10).map(w=><button className="home-walk" key={w.id} onClick={()=>{setWalk(w);show('walk')}}><span>{dateLabel(w.date)} · {clock(w.start,data.timezone)}–{clock(w.end,data.timezone)}</span><span>{w.ignored?'已忽略':`${Math.round((Date.parse(w.end)-Date.parse(w.start))/60000)} 分钟`} ›</span></button>)}{!data.walks.length&&<p className="home-note">暂无已同步的散步记录</p>}</>}
      {detail==='walk'&&walk&&<WalkEditor walk={walk} timezone={data.timezone} busy={busy} onSave={v=>mutate(()=>saveHomeWalk(v))}/>}
      {detail==='activity'&&<><p className="home-lead">{dateLabel(d.date)} · {num(d.activity)} 千卡</p><Rows rows={ [['全天活动热量',`${num(d.total_energy)} 千卡`],['力量训练时段',`${num(d.strength_energy)} 千卡`],['日常活动热量',`${num(d.activity)} 千卡`],['本周累计',`${num(weekEnergy)} / ${num(data.goals.weeklyActivity)} 千卡`],['周累计覆盖',`${energies.length} / ${currentWeek.length} 天`],['读取范围截至',d.cutoff?clock(d.cutoff,data.timezone):'待更新']] }/><p className="home-note">活动热量已不含基础代谢，按已记录的力量训练时段拆分。{data.goals.basis}</p></>}
      {detail==='training'&&<><p className="home-lead">{dateLabel(d.date)} · {d.strength_planned?`${d.sets} / ${d.target} 组`:'按计划休息'}</p>{d.sessions.map(s=><button className="home-walk" key={s.id} onClick={()=>onTraining?.({session_id:s.id})}><span>{s.title}</span><span>记录与进步 ›</span></button>)}{isToday&&<button className="home-primary" onClick={launch}>{actionLabel}</button>}</>}
      {detail==='posture'&&<><p className="home-lead">轻负荷练习 · 约 5–8 分钟</p><Rows rows={ [['靠墙滑手','1 × 8–12 次'],['胸椎伸展','1 × 6–8 次'],['胸肌拉伸','每侧 2 × 20–30 秒']] }/>{d.posture_recorded&&<><p className="home-note">已根据训练记录计入今天，周进度同步更新。</p>{d.posture_sessions.map(s=><button className="home-walk" key={s.id} onClick={()=>{setDetail(null);onTraining?.({session_id:s.id})}}><span>{s.title}</span><span>查看记录 ›</span></button>)}</>}{!d.posture_recorded&&<p className="home-note">完成体态训练后自动计入。</p>}{isToday&&!d.posture_recorded&&<button className="home-primary" onClick={()=>{setDetail(null);onTraining?.({template_id:'posture-daily'})}}>查看体态训练</button>}</>}
      {detail==='sync'&&<><h3 className="home-detail-heading">Google 返回的实际记录</h3><Rows rows={ [['步数记录',observedText(freshness.records?.steps?.observed_at)],['活动热量记录',observedText(freshness.records?.activity?.observed_at)]] }/><p className="home-note">按活动明细的实际记录时间显示距今多久。</p>{freshness.device?.last_sync_at&&<><h3 className="home-detail-heading">手环上次同步</h3><Rows rows={ [['设备',freshness.device.device_name||'Fitbit'],['同步时间',observedText(freshness.device.last_sync_at)]] }/></>}{freshness.device?.status==='permission_required'&&<><p className="home-note">开启手环同步时间，需要补充 Google“设备设置”只读授权。</p><a className="home-primary home-permission-link" href="/api/auth/login?device_sync=true">开启设备同步时间</a></>}<h3 className="home-detail-heading">App 最近读取</h3><Rows rows={Object.entries(data.sources).map(([key,s])=>[({metrics:'每日指标',sleep:'睡眠',weight:'体重',activity:'活动拆分',walks:'散步记录'})[key],s.fetched_at?`${dateLabel(s.fetched_at.slice(0,10))} ${clock(s.fetched_at,data.timezone)}`:'待更新'])}/><button className="home-primary" disabled={refreshing} onClick={()=>{setDetail(null);setAttempt(n=>n+1)}}>重新读取数据</button></>}
    </div></Modal>}
  </div>
}
