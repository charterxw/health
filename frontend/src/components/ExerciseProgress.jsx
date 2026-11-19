import { useEffect, useMemo, useState } from 'react'
import Modal from './Modal'
import { ExerciseContent } from './TrainingLibrary'
import { getExerciseProgress } from '../api/client'
import { exercisePoints, mergeExerciseHistory, metricPoints } from '../training/exerciseProgress'
import { weightUnitLabel } from '../training/strength'
import '../training/progress.css'

const modes = { external: '外加负重', assistance: '辅助重量', bodyweight: '自重' }
export default function ExerciseProgress({ exercise, history, deletedIds = new Set(), onClose }) {
  const id = exercise.exercise_id || exercise.id
  const timed = exercise.tracking === 'duration'
  const historyLabel = exercise.training_type === 'mobility' ? '练习记录' : '长期进步'
  const preference=useMemo(()=>{try{return JSON.parse(localStorage.getItem('health-progress-view-'+id))||{}}catch{return {}}},[id])
  const [tab, setTab] = useState(exercise.initialTab||'progress')
  const [remote, setRemote] = useState(null)
  const [error, setError] = useState(false)
  const [attempt, setAttempt] = useState(0)
  const [days, setDays] = useState(['28','84','all'].includes(preference.days)?preference.days:'28')
  const [unit, setUnit] = useState(preference.unit||exercise.unit || 'lb')
  const [mode, setMode] = useState(exercise.load_mode || 'external')
  const [metric, setMetric] = useState(preference.metric||(timed||exercise.load_mode==='bodyweight'?'peak':'total'))
  const [load, setLoad] = useState('')
  const [template,setTemplate]=useState(exercise.template_id||'')
  const [selected, setSelected] = useState(null)
  useEffect(()=>{try{localStorage.setItem('health-progress-view-'+id,JSON.stringify({days,unit,metric}))}catch{}},[id,days,unit,metric])
  useEffect(() => {
    const controller = new AbortController()
    setError(false); setRemote(null)
    getExerciseProgress(id, controller.signal).then(result => { if (!controller.signal.aborted) setRemote(result.records) })
      .catch(() => { if (!controller.signal.aborted) setError(true) })
    return () => controller.abort()
  }, [id, attempt])
  const records = useMemo(() => mergeExerciseHistory(remote || [], history, deletedIds, remote != null), [remote, history, deletedIds])
  const scopedRecords=template?records.filter(r=>r.session.template_id===template):records
  const points = exercisePoints(scopedRecords, id, { unit, mode, days: days === 'all' ? null : Number(days) })
  const loads = [...new Set(points.flatMap(p => p.sets.map(s => s.weight)))].filter(n => n != null).sort((a, b) => a - b)
  const chosenLoad = loads.includes(Number(load)) && load !== '' ? Number(load) : points.at(-1)?.sets[0]?.weight ?? loads.at(-1)
  const chart = metricPoints(points, mode === 'bodyweight' && metric === 'reps' ? 'peak' : metric, chosenLoad)
  const shown = chart.slice(-80)
  const current = chart.find(p => p.id === selected) || chart.at(-1)
  const label = metric==='total'?`${chosenLoad??'—'} ${weightUnitLabel(unit)}同重量总次数`:metric === 'sets' ? '工作组数' : metric === 'reps' && mode !== 'bodyweight' ? `${chosenLoad ?? '—'} ${weightUnitLabel(unit)}最佳单组次数`
    : timed ? '单组时长' : mode === 'bodyweight' ? '最佳单组次数' : mode === 'assistance' ? '最少辅助重量' : '最重工作组'
  const suffix = metric === 'sets' ? '组' : timed ? '秒' : ['reps','total'].includes(metric) || mode === 'bodyweight' ? '次' : weightUnitLabel(unit)
  const low = Math.min(...shown.map(p => p.value)), high = Math.max(...shown.map(p => p.value))
  const x=i=>shown.length>1?42+(Date.parse(shown[i].date)-Date.parse(shown[0].date))*526/Math.max(1,Date.parse(shown.at(-1).date)-Date.parse(shown[0].date)):305
  const y = n => high === low ? 100 : 160 - (n - low) / (high - low) * 120
  return <Modal title={`${exercise.name} · ${historyLabel}`} onClose={onClose} wide>
    <div className="st-page-tabs" role="tablist" aria-label="动作详情">{[['progress', historyLabel], ['guide', '中文说明']].map(([key, name]) => <button key={key} role="tab" aria-selected={tab === key} onClick={() => setTab(key)}>{name}</button>)}</div>
    {tab === 'guide' ? <ExerciseContent exercise={exercise} /> : <div className="st-progress">
      <p className="st-muted">{remote ? '全部已保存训练 + 已缓存训记档案' : error ? '完整历史暂不可用，当前仅显示本机缓存。' : '正在读取完整历史；先显示本机记录…'}{error && <button className="st-text-button" onClick={() => setAttempt(n => n + 1)}>重试</button>}</p>
      <div className="st-filter-chips" aria-label="进步时间范围">{[['28','近四周'],['84','近十二周'],['all','全部']].map(([v,label])=><button key={v} aria-pressed={days===v} onClick={()=>setDays(v)}>{label}</button>)}</div>
      {points.length > 0 && <div className="st-progress-stats"><span><b>{points.length}</b> 次训练</span><span><b>{points.reduce((n, p) => n + p.workSets, 0)}</b> 个工作组</span><span>{points[0].day} 至 {points.at(-1).day}</span></div>}
      {!chart.length ? <div className="st-empty">这个范围和记重方式下还没有已完成的工作组。<details className="st-progress-options"><summary>调整指标与筛选</summary>      <div className="st-progress-filters">
        <label>训练安排<select value={template} onChange={e=>setTemplate(e.target.value)}><option value="">全部安排</option>{[...new Map(records.filter(r=>r.session.template_id).map(r=>[r.session.template_id,r.session.title])).entries()].map(([id,title])=><option key={id} value={id}>{title}</option>)}</select></label>
        <label>时间范围<select value={days} onChange={e => setDays(e.target.value)}><option value="28">近 4 周</option><option value="84">近 12 周</option><option value="all">全部历史</option></select></label>
        {!timed && <label>记重方式<select value={mode} onChange={e => { setMode(e.target.value); setMetric('peak') }}>{Object.entries(modes).map(([key, name]) => <option key={key} value={key}>{name}</option>)}</select></label>}
        {mode !== 'bodyweight' && <label>显示单位<select value={unit} onChange={e => { setUnit(e.target.value); setLoad('') }}><option value="lb">磅</option><option value="kg">公斤</option></select></label>}
        <label>观察指标<select value={metric} onChange={e => setMetric(e.target.value)}><option value="peak">{timed ? '单组时长' : mode === 'bodyweight' ? '最佳单组次数' : mode === 'assistance' ? '最少辅助重量' : '最重工作组'}</option>{mode !== 'bodyweight' && <><option value="reps">同重量最佳次数</option><option value="total">同重量总次数</option></>}<option value="sets">工作组数</option></select></label>
        {['reps','total'].includes(metric) && mode !== 'bodyweight' && <label>比较重量<select value={chosenLoad ?? ''} onChange={e => setLoad(e.target.value)}>{loads.map(n => <option key={n} value={n}>{n} {weightUnitLabel(unit)}</option>)}</select></label>}
      </div></details></div> : <>
        <h3>{label}</h3>
        <p className="st-progress-insight">{chart.length===1?'本次基线 · ':''}{chart[0].day}：{chart[0].value} {suffix} → {chart.at(-1).day}：{chart.at(-1).value} {suffix}</p>
        {metric==='total'&&<p className="st-muted">同重量组数：{chart[0].matchingSets} → {chart.at(-1).matchingSets} 组{chart[0].matchingSets===chart.at(-1).matchingSets&&chart[0].template_id===chart.at(-1).template_id?'':' · 组数或安排变化，按各次实际记录查看'}</p>}
        <p className="st-muted">{mode === 'assistance' && metric === 'peak' ? '辅助量越少，所需自身发力越大。' : '只统计勾选完成的工作组。'}{metric === 'peak' && mode !== 'bodyweight' && '重量变化需结合次数与动作质量判断。'}</p>
        <svg className="st-progress-chart" viewBox="0 0 600 200" role="img" aria-label={`${label}，${shown.length} 次训练，按实际日期排列`}>
          <line x1="42" y1="160" x2="568" y2="160" stroke="currentColor" opacity=".18" />
          <text x="5" y="44">{high}</text><text x="5" y="164">{low}</text>
          <polyline points={shown.map((p, i) => `${x(i)},${y(p.value)}`).join(' ')} fill="none" stroke="currentColor" strokeWidth="2.5" />
          {shown.map((p,i)=><g key={p.id} tabIndex={0} role="button" aria-label={`${p.day} ${p.value} ${suffix}`} onClick={()=>setSelected(p.id)} onKeyDown={e=>{if(['Enter',' '].includes(e.key)){e.preventDefault();setSelected(p.id)}}}><circle cx={x(i)} cy={y(p.value)} r="30" fill="transparent"/><circle cx={x(i)} cy={y(p.value)} r={p.id===current.id?6:4} fill="currentColor"/></g>)}
          <text x="42" y="191">{shown[0].day}</text><text x="568" y="191" textAnchor="end">{shown.at(-1).day}</text>
        </svg>
        {chart.length > 80 && <p className="st-muted">图中显示最近 80 次；上方统计覆盖所选完整范围。</p>}
        <details className="st-progress-options"><summary>调整指标与筛选</summary>      <div className="st-progress-filters">
        <label>训练安排<select value={template} onChange={e=>setTemplate(e.target.value)}><option value="">全部安排</option>{[...new Map(records.filter(r=>r.session.template_id).map(r=>[r.session.template_id,r.session.title])).entries()].map(([id,title])=><option key={id} value={id}>{title}</option>)}</select></label>
        <label>时间范围<select value={days} onChange={e => setDays(e.target.value)}><option value="28">近 4 周</option><option value="84">近 12 周</option><option value="all">全部历史</option></select></label>
        {!timed && <label>记重方式<select value={mode} onChange={e => { setMode(e.target.value); setMetric('peak') }}>{Object.entries(modes).map(([key, name]) => <option key={key} value={key}>{name}</option>)}</select></label>}
        {mode !== 'bodyweight' && <label>显示单位<select value={unit} onChange={e => { setUnit(e.target.value); setLoad('') }}><option value="lb">磅</option><option value="kg">公斤</option></select></label>}
        <label>观察指标<select value={metric} onChange={e => setMetric(e.target.value)}><option value="peak">{timed ? '单组时长' : mode === 'bodyweight' ? '最佳单组次数' : mode === 'assistance' ? '最少辅助重量' : '最重工作组'}</option>{mode !== 'bodyweight' && <><option value="reps">同重量最佳次数</option><option value="total">同重量总次数</option></>}<option value="sets">工作组数</option></select></label>
        {['reps','total'].includes(metric) && mode !== 'bodyweight' && <label>比较重量<select value={chosenLoad ?? ''} onChange={e => setLoad(e.target.value)}>{loads.map(n => <option key={n} value={n}>{n} {weightUnitLabel(unit)}</option>)}</select></label>}
      </div></details>
        <label className="st-progress-select">查看某次训练<select value={current.id} onChange={e => setSelected(e.target.value)}>{[...chart].reverse().map(p => <option key={p.id} value={p.id}>{p.day} · {p.title} · {p.value} {suffix}</option>)}</select></label>
        <div className="st-history-detail"><strong>{current.day} · {current.title}</strong><small>{current.source === 'archive' ? '训记档案' : '本 App 记录'} · {label} {current.value} {suffix}</small>
          {current.sets.map((s, i) => <p key={`${s.id}-${i}`}><span>工作组 {i + 1}</span><b>{timed ? `${s.duration_seconds} 秒` : `${mode === 'bodyweight' ? '自重' : `${mode === 'assistance' ? '辅助 ' : ''}${s.weight} ${weightUnitLabel(unit)}`} × ${s.reps}`}</b></p>)}
        </div>
      </>}
    </div>}
  </Modal>
}
