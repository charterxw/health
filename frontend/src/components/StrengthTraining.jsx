import { useContext, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { createStrengthExercise, saveStrengthTemplate } from '../api/client'
import useStrengthStore from '../training/useStrengthStore'
import TrainingHeaderContext from './TrainingHeaderContext'
import TrainingReport from './TrainingReport'
import TrainingRound from './TrainingRound'
import TemplateLibrary from './TemplateLibrary'
import ExerciseProgress from './ExerciseProgress'
import { nextRoutine, sessionTemplate, templateCounts } from '../training/programs'
import { BodyMap, ExerciseBrowser, ExerciseContent, WeeklyTraining, PrescriptionHint } from './TrainingLibrary'
import { templateMuscles, MUSCLE_NAMES, MUSCLE_IDS } from '../training/muscles'
import { nextPrescription, prescriptionLabel } from '../training/progression'
import WorkoutRecords from './WorkoutRecords'
import Modal from './Modal'
import TrainingNumberInput from './TrainingNumberInput'
import { workoutSnapshot, publishNativeWorkout, isNativeHealth, hasNativeCapability, nativeRequest } from '../native/bridge'
import NativeScreenContext from '../native/NativeScreenContext'
import {
  weightUnitLabel, clone, uid, newMovement, startSession, previousSets, convertWeight,
  elapsedSeconds, clockText, summary, togglePause, finishSession, prefillEmptySession,
  fillFollowingSets, appendExerciseSet, adoptPrescription, isTimed, setValue, hasSetValue,
  changeTemplatePlan, remainingPlan, targetLabel, targetHistory,
} from '../training/strength'
import '../training/strength.css'
import '../training/ux.css'
import SetOptions, {SetNumber} from './SetOptions'
import {feedbackSummary,removeSessionSet} from '../training/setFeedback'
import {workProgress,isPosture,setLabel,finishMessage,toggleSet,sameContext,lastPerformance,replacementMovement} from '../training/ux'
import TrainingFocus from './TrainingFocus'
import RecordCorrection from './RecordCorrection'

const useBrowserLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect

function TrainingToolbar({ active, children }) {
  const host = useContext(TrainingHeaderContext)
  return active && host ? createPortal(children, host) : children
}

function Icon({ name, size = 20, ...props }) {
  const paths = {
    plus: <path d="M12 5v14M5 12h14" />,
    close: <path d="m6 6 12 12M6 18 18 6" />,
    check: <path d="m5 12 4 4L19 6" />,
    play: <path d="m8 5 11 7-11 7Z" />,
    pause: <path d="M8 5v14M16 5v14" />,
    back: <path d="m15 5-7 7 7 7" />,
    clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
    arrow: <path d="m9 5 7 7-7 7" />,
    edit: <><path d="m15 4 5 5M4 20l5-1L21 7l-5-5L4 14Z" /></>,
    list: <><path d="M9 6h12M9 12h12M9 18h12" /><circle cx="3.5" cy="6" r=".5" /><circle cx="3.5" cy="12" r=".5" /><circle cx="3.5" cy="18" r=".5" /></>,
    down: <path d="m6 9 6 6 6-6" />,
    circle: <circle cx="12" cy="12" r="8" />,
    fill: <><path d="M12 3v12m-4-4 4 4 4-4M5 19h14M5 22h14" /></>,
    trash: <><path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7" /></>,
  }
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>{paths[name]}</svg>
}

function ExerciseGlyph({ exercise, small = false }) {
  const cable = /绳索|下拉/.test(exercise.equipment || '')
  return <span className={`st-glyph ${small ? 'small' : ''}`} aria-hidden="true">
    <svg width="32" height="32" viewBox="0 0 40 40" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
      {cable ? <><path d="M9 33V7h22v26M5 33h9m12 0h9M20 7v13m-6 3 6-3 6 3" /><circle cx="20" cy="7" r="3" /></>
        : <><path d="M6 20h28M10 11v18m5-15v12m10-12v12m5-15v18" /></>}
    </svg>
  </span>
}


function ExercisePicker({ exercises, onPick, onCreated, onClose }) {
  const [search, setSearch] = useState('')
  const [creating, setCreating] = useState(false)
  const [preview, setPreview] = useState(null)
  const [muscle, setMuscle] = useState('')
  const [mode, setMode] = useState('external')
  const [equipment, setEquipment] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function addCustom(e) {
    e.preventDefault()
    setBusy(true); setError('')
    try {
      const exercise = await createStrengthExercise({ id: uid(), name: search.trim(), muscles: muscle ? [MUSCLE_NAMES[muscle]] : [], primary_muscles: muscle ? [muscle] : [], equipment, load_mode: mode })
      onCreated(exercise); onPick(exercise)
    } catch (err) { setError(err.message) } finally { setBusy(false) }
  }
  return <Modal title={preview ? preview.name : '添加动作'} onClose={onClose}>
    {preview ? <>
      <button className="st-text-button" onClick={() => setPreview(null)}>‹ 返回动作列表</button>
      <ExerciseContent exercise={preview} />
      <button className="st-primary st-wide" onClick={() => onPick(preview)}>添加这个动作</button>
    </> : <>
    <ExerciseBrowser exercises={exercises} onPick={onPick} onInfo={setPreview} picking />
    {!creating ? <button className="st-secondary st-wide" onClick={() => setCreating(true)}><Icon name="plus" /> 自定义动作</button> :
      <form className="st-custom-form" onSubmit={addCustom}>
        <label>动作名称<input required maxLength={100} value={search} onChange={e => setSearch(e.target.value)} placeholder="输入新动作名称" /></label>
        <label>器械<input maxLength={40} value={equipment} onChange={e => setEquipment(e.target.value)} placeholder="可选" /></label>
        <label>主要肌群<select value={muscle} onChange={e => setMuscle(e.target.value)}><option value="">暂不填写</option>{MUSCLE_IDS.map(id => <option key={id} value={id}>{MUSCLE_NAMES[id]}</option>)}</select></label>
        <label>记重方式<select value={mode} onChange={e => setMode(e.target.value)}><option value="external">外加负重</option><option value="assistance">辅助重量</option><option value="bodyweight">自重</option></select></label>
        <button className="st-primary st-wide" disabled={busy || !search.trim()}>{busy ? '保存中…' : '保存并添加'}</button>
      </form>}
    {error && <p className="st-error" role="alert">{error}</p>}
    </>}
  </Modal>
}

function TemplateEditor({ record, exercises, onSave, onClose }) {
  const [draft, setDraft] = useState(() => clone(record.template))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [closing,setClosing]=useState(false)
  const changed=JSON.stringify(draft)!==JSON.stringify(record.template)
  const requestClose=()=>{if(busy)return;if(changed)setClosing(true);else onClose()}
  const changeCounts=(index,work,warm)=>setDraft(old=>({...old,exercises:old.exercises.map((m,i)=>{if(i!==index)return m;const next=changeTemplatePlan(m,'set_count',Number(work)+Number(warm));if(m.set_targets)next.set_targets=m.set_targets.map(t=>({...t}));return changeTemplatePlan({...next,warmup_count:m.warmup_count},'warmup_count',Number(warm))})}))
  const [addId, setAddId] = useState(exercises[0]?.id || '')
  const change = (index, key, value) => setDraft(old => ({ ...old, exercises: old.exercises.map((m, i) => i === index
    ? changeTemplatePlan(m, key, value) : m) }))
  const changeTarget = (index, row, key, value) => setDraft(old => ({ ...old, exercises: old.exercises.map((m, i) => i !== index ? m : {
    ...m, targets_updated_at: new Date().toISOString(),
    set_targets: m.set_targets.map((target, n) => n === row ? { ...target, [key]: value } : target),
  }) }))
  const enableTargets = index => setDraft(old => ({ ...old, exercises: old.exercises.map((m, i) => i !== index ? m : {
    ...m, warmup_count: m.warmup_count ?? 0, targets_updated_at: new Date().toISOString(),
    set_targets: Array.from({ length: Number(m.set_count) || 3 }, () => ({ weight: null, reps: m.target_reps || 8 })),
  }) }))
  const move = (index, step) => setDraft(old => {
    const next = clone(old); const to = index + step
    if (to >= 0 && to < next.exercises.length) [next.exercises[index], next.exercises[to]] = [next.exercises[to], next.exercises[index]]
    return next
  })
  async function save(e) {
    e.preventDefault(); setBusy(true); setError('')
    if (draft.exercises.some(plan => plan.progression === 'double' && (!(Number(plan.rep_min ?? 8) <= Number(plan.rep_max ?? 12)) || Number(plan.rep_min ?? 8) < 1))) {
      setError('进阶次数上限不能小于下限。'); setBusy(false); return
    }
    if (draft.exercises.some(p => p.warmup_count != null && p.warmup_count >= p.set_count)) { setError('总组数应大于热身组数，至少保留一个工作组。'); setBusy(false); return }
    try { onSave(await saveStrengthTemplate(draft, record.version)); onClose() }
    catch (err) { setError(err.message) } finally { setBusy(false) }
  }
  return <Modal title={record.version ? '编辑模板' : '保存为模板'} onClose={requestClose} wide>
    {closing&&<div className="st-draft-guard" role="alert"><strong>模板有未保存的修改</strong><button className="st-secondary" onClick={()=>setClosing(false)}>继续编辑</button><button className="st-text-button" onClick={onClose}>放弃修改</button></div>}
    <form onSubmit={save} className="st-template-form">
      <label>模板名称<input required maxLength={100} value={draft.name} onChange={e => setDraft({ ...draft, name: e.target.value })} /></label>
      <label>训练提示<textarea maxLength={2000} value={draft.notes || ''} onChange={e => setDraft({ ...draft, notes: e.target.value })} /></label>
      <p className="st-muted">修改只用于之后开始的训练，历史记录会保留原样。</p>
      {draft.exercises.map((plan, i) => <div className="st-plan-row" key={`${i}-${plan.exercise_id}`}>
        <div className="st-plan-heading"><span className="st-index">{i + 1}</span><strong>{exercises.find(e => e.id === plan.exercise_id)?.name || plan.exercise_id}</strong>
          <button type="button" className="st-text-button" disabled={!i} aria-label="动作上移" onClick={() => move(i, -1)}>↑</button>
          <button type="button" className="st-text-button" disabled={i === draft.exercises.length - 1} aria-label="动作下移" onClick={() => move(i, 1)}>↓</button>
          <button type="button" className="st-icon-button" aria-label="移除模板动作" onClick={() => setDraft({ ...draft, exercises: draft.exercises.filter((_, index) => index !== i) })}><Icon name="close" size={15} /></button>
        </div>
        <div className="st-plan-fields">
          <label>工作组<input aria-label={`${i + 1}号动作组数`} type="number" required min="1" max="30" value={plan.set_count-(plan.warmup_count||0)} onChange={e=>changeCounts(i,Math.max(1,Math.min(30-(plan.warmup_count||0),Number(e.target.value)||1)),plan.warmup_count||0)} /></label>
          <label>热身组<select value={plan.warmup_count??0} onChange={e=>changeCounts(i,plan.set_count-(plan.warmup_count||0),Number(e.target.value))}>{Array.from({length:Math.min(11,31-(plan.set_count-(plan.warmup_count||0)))},(_,n)=><option key={n} value={n}>{n} 组</option>)}</select></label>
          {isTimed(exercises.find(e => e.id === plan.exercise_id) || {})
            ? <label>目标时长 / 秒<input type="number" min="1" max="3600" placeholder="留空" value={plan.target_seconds ?? ''} onChange={e => change(i, 'target_seconds', e.target.value === '' ? null : Number(e.target.value))} /></label>
            : <label>目标次数<input type="number" min="1" max="1000" placeholder="留空" value={plan.target_reps ?? ''} onChange={e => change(i, 'target_reps', e.target.value === '' ? null : Number(e.target.value))} /></label>}
          {exercises.find(e => e.id === plan.exercise_id)?.load_mode !== 'bodyweight' && <label>单位<select value={plan.unit} onChange={e => change(i, 'unit', e.target.value)}><option value="lb">磅</option><option value="kg">公斤</option></select></label>}
          <label>休息 / 秒<input type="number" required min="0" max="600" value={plan.rest_seconds} onChange={e => change(i, 'rest_seconds', e.target.value === '' ? '' : Number(e.target.value))} /></label>
        </div>
        {!isTimed(exercises.find(e => e.id === plan.exercise_id) || {}) && <details className="st-preset-editor">
          <summary>逐组重量与次数</summary>
          <p className="st-muted">首次按预设开始，之后沿用本模板的实际记录。修改预设后，下次重新使用新目标。</p>
          {plan.set_targets ? plan.set_targets.map((target, n) => <div className="st-preset-row" key={n}>
            <span>{n < (plan.warmup_count || 0) ? `热身 ${n + 1}` : `正式 ${n + 1 - (plan.warmup_count || 0)}`}</span>
            <label>重量 / {weightUnitLabel(plan.unit)}<input aria-label={`${i + 1}号动作第${n + 1}组预设重量`} type="number" min="0" max="2000" step="any" value={target.weight ?? ''} placeholder="自定" onChange={e => changeTarget(i, n, 'weight', e.target.value === '' ? null : Number(e.target.value))} /></label>
            <label>次数<input aria-label={`${i + 1}号动作第${n + 1}组预设次数`} type="number" required min="1" max="1000" value={target.reps ?? ''} onChange={e => changeTarget(i, n, 'reps', e.target.value === '' ? '' : Number(e.target.value))} /></label>
          </div>) : <button className="st-secondary" type="button" onClick={() => enableTargets(i)}>设置逐组目标</button>}
        </details>}
        {exercises.find(e => e.id === plan.exercise_id)?.training_type !== 'mobility' && !isTimed(exercises.find(e => e.id === plan.exercise_id) || {}) && <div className="st-plan-progression">
          <label>双重进阶 · 自动填入下次目标<input type="checkbox" aria-label={`${i + 1}号动作启用进阶`} checked={plan.progression === 'double'} onChange={e => change(i, 'progression', e.target.checked ? 'double' : 'off')} /></label>
          {plan.progression === 'double' && <><div className="st-plan-fields">
            <label>次数下限<input type="number" required min="1" max="100" value={plan.rep_min ?? 8} onChange={e => change(i, 'rep_min', e.target.value === '' ? '' : Number(e.target.value))} /></label>
            <label>次数上限<input type="number" required min={plan.rep_min || 1} max="100" value={plan.rep_max ?? 12} onChange={e => change(i, 'rep_max', e.target.value === '' ? '' : Number(e.target.value))} /></label>
            <label>重量步长 / {weightUnitLabel(plan.unit)}<input type="number" required min="0.01" max="100" step="0.01" value={plan.increment ?? (plan.unit === 'kg' ? 2.5 : 5)} onChange={e => change(i, 'increment', e.target.value === '' ? '' : Number(e.target.value))} /></label>
          </div><p>全部工作组达到次数上限后才建议加重；辅助动作减少辅助量。步长按实际器械填写，热身组不计。</p></>}
        </div>}
      </div>)}
      <div className="st-inline-add"><select aria-label="选择模板动作" value={addId} onChange={e => setAddId(e.target.value)}>{exercises.map(e => <option key={e.id} value={e.id}>{e.name}</option>)}</select>
        <button type="button" className="st-secondary" disabled={draft.exercises.length >= 40} onClick={() => setDraft({ ...draft, exercises: [...draft.exercises, { exercise_id: addId, set_count: 3, unit: 'lb', rest_seconds: 90, target_reps: null }] })}><Icon name="plus" /> 添加</button></div>
      {error && <p className="st-error" role="alert">{error}</p>}
      <button className="st-primary st-wide" disabled={busy || !draft.exercises.length || !draft.name.trim()}>{busy ? '保存中…' : '保存模板'}</button>
    </form>
  </Modal>
}

function dateText(value, withTime = false) {
  return new Date(value.length === 10 ? `${value}T12:00:00` : value).toLocaleString('zh-CN', {
    month: 'long', day: 'numeric', ...(withTime ? { hour: '2-digit', minute: '2-digit' } : {}),
  })
}

function importedHistory(workouts, exercises) {
  const key = name => String(name).normalize('NFKC').replace(/\s/g, '')
  return workouts.map((workout, i) => ({ session: {
    id: `imported:${workout.localid || i}:${workout.datestr}`, title: workout.title || '训记',
    status: 'completed', started_at: workout.datestr,
    exercises: workout.movements.flatMap((movement, mi) => {
      const exercise = exercises.find(e => key(e.name) === key(movement.name))
      if (!exercise) return []
      const loadMode = movement.exetype === 'help' ? 'assistance' : movement.exetype === 'self' ? 'bodyweight' : exercise.load_mode
      if (loadMode !== exercise.load_mode) return []
      const byUnit = {}
      movement.sets.filter(s => s.done !== false).forEach((s, si) => {
        const unit = s.unit === 'lbs' ? 'lb' : s.unit
        if (!['lb', 'kg'].includes(unit) || s.weight === '' || s.weight == null || !Number.isFinite(Number(s.weight)) || !(Number(s.reps) > 0)) return
        if (!byUnit[unit]) byUnit[unit] = []
        byUnit[unit].push({ id: `${mi}-${si}`, weight: Number(s.weight), reps: Number(s.reps), completed_at: workout.datestr, warmup: Boolean(s.warmup) })
      })
      return Object.entries(byUnit).map(([unit, sets]) => ({ id: `${mi}-${unit}`, exercise_id: exercise.id, name: exercise.name,
        load_mode: loadMode, unit, sets }))
    }),
  } }))
}

export default function StrengthTraining({ active, showRecords = false, onOpenTraining, onReturnToRecords, homeRequest }) {
  const store = useStrengthStore()
  const setNativeScreen = useContext(NativeScreenContext)
  const nativeState = useRef(null)
  const nativeAlive = useRef(true)
  const requestedId = useRef(typeof window === 'undefined' ? null : new URLSearchParams(window.location.search).get('workout')?.toLowerCase())
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(requestedId.current || '')) requestedId.current = null
  const requestedLoaded = useRef(false)
  const [requestedError, setRequestedError] = useState('')
  const section = 'templates'
  const [openedFromRecords, setOpenedFromRecords] = useState(false)
  const [selectedId, setSelectedId] = useState(() => requestedId.current || store.active?.session.id || null)
  const [expanded, setExpanded] = useState(() => store.active?.session.exercises.find(m => m.sets.some(s => !s.completed_at))?.id || store.active?.session.exercises[0]?.id || null)
  const [exerciseMenu, setExerciseMenu] = useState(false)
  const [picker, setPicker] = useState(false)
  const [editing, setEditing] = useState(null)
  const [previewTemplate, setPreviewTemplate] = useState(null)
  const [exerciseHistory, setExerciseHistory] = useState(null)
  const [settingsId, setSettingsId] = useState(null)
  const [groupOptions,setGroupOptions]=useState(null)
  const [groupHint,setGroupHint]=useState(()=>{try{return !localStorage.getItem('health-set-options-used')}catch{return true}})
  const [sessionTools, setSessionTools] = useState(null)
  const [confirm, setConfirm] = useState(null)
  const [deleteId, setDeleteId] = useState(null)
  const [deleteError, setDeleteError] = useState(null)
  const [correction,setCorrection]=useState(null)
  const [replaceId,setReplaceId]=useState(null)
  const recordsScroll=useRef(0)
  const [message, setMessage] = useState('')
  const [setSources, setSetSources] = useState({})
  const [fillNotice, setFillNotice] = useState('')
  const [now, setNow] = useState(Date.now())
  const appRef = useRef(null)
  const prefilled = useRef(new Set())
  const handledHome = useRef(null)
  const editBaselines = useRef({})
  const exercises = store.catalog?.exercises || []
  const planOrder = ["guided-upper-a", "personal-home-a", "guided-lower-a", "personal-home-b", "guided-upper-b", "personal-home-c", "guided-lower-b", "personal-home-d", "personal-weekend-saturday", "personal-weekend-sunday"]
  const templates = [...(store.catalog?.templates || [])].sort((a, b) => { const ai = planOrder.indexOf(a.template.id), bi = planOrder.indexOf(b.template.id); return (ai < 0 ? 100 : ai) - (bi < 0 ? 100 : bi) })
  const [roundData,setRoundData]=useState(null)
  const routineRecord=templates.find(r=>r.template.id===(roundData?.plan?.current?.slots?.find(s=>!s.completed)?.template_id || roundData?.plan?.next?.template_id))
  const routine=routineRecord?{record:routineRecord}:null
  useEffect(() => {
    if (!active || !store.ready || !homeRequest || handledHome.current === homeRequest.nonce) return
    handledHome.current = homeRequest.nonce
    setSelectedId(null)
    if (homeRequest.session_id) {
      setSelectedId(homeRequest.session_id)
      store.load(homeRequest.session_id).catch(() => setMessage('暂时无法打开训练记录，请重试。'))
    } else if (store.active) {
      setSelectedId(store.active.session.id)
    } else if (homeRequest.template_id) {
      const found = templates.find(r => r.template.id === homeRequest.template_id)?.template
      if (found) {
        const pending = new Map((homeRequest.remaining || []).map(m => [m.exercise_id, m.target]))
        const template = pending.size ? { ...found, exercises: found.exercises.filter(m => pending.has(m.exercise_id)).map(m => pending.get(m.exercise_id)>=m.set_count-(m.warmup_count||0)?m:remainingPlan(m, pending.get(m.exercise_id))) } : found
        setPreviewTemplate(template)
      }
    }
  }, [active, store.ready, homeRequest, store.active, store.catalog])
  useEffect(()=>{if(active&&openedFromRecords){setOpenedFromRecords(false);setSelectedId(store.active?.session.id||null)}},[active])
  const record = store.records[selectedId]
  const deleteRecord = store.records[deleteId]
  const session = record?.session
  const ongoing = session?.status === 'active'
  useEffect(()=>setGroupOptions(null),[session?.id])
  const stats = session ? summary(session) : null
  const work = session ? workProgress(session) : null
  const recordView=showRecords&&openedFromRecords&&session?.status==='completed'
  const visible=active||recordView
  const hints = useMemo(() => [...store.history, ...importedHistory(store.imported, exercises)].sort((a, b) => b.session.started_at.localeCompare(a.session.started_at)), [store.history, store.imported, exercises])
  const nativeWorkout = useMemo(() => workoutSnapshot(store.active?.session,
    store.active?.session.id === selectedId ? expanded : null), [store.active?.session, selectedId, expanded])

  useEffect(() => {
    if (!store.ready || !isNativeHealth()) return
    publishNativeWorkout(nativeWorkout)
    const resume = () => publishNativeWorkout(nativeWorkout, true)
    window.addEventListener('health-native-resume', resume)
    return () => window.removeEventListener('health-native-resume', resume)
  }, [store.ready, nativeWorkout])

  useEffect(() => {
    if (!isNativeHealth()) return
    let alive = true, request = 0
    const open = event => {
      const id = event.detail
      if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id || '')) return
      const ticket = ++request
      setOpenedFromRecords(false); setSelectedId(id); setMessage(''); setRequestedError('')
      if (!store.records[id]) store.load(id).catch(error => {
        if (!alive || ticket !== request) return
        setSelectedId(current => current === id ? null : current)
        setRequestedError(error.status === 404 || error.status === 410 ? '这场训练不存在或已删除。' : '这场训练暂时无法打开，请检查网络。')
      })
    }
    window.addEventListener('health-native-open-workout', open)
    return () => { alive = false; window.removeEventListener('health-native-open-workout', open) }
  }, [store.records, store.load])

  useEffect(() => {
    if (!store.ready || !requestedId.current || requestedLoaded.current) return
    requestedLoaded.current = true
    if (!store.records[requestedId.current]) store.load(requestedId.current).catch(error => setRequestedError(error.status === 404 ? '这场训练不存在或已删除。' : '暂时无法打开这场训练，请稍后刷新。'))
  }, [store.ready, store.records, store.load])

  useEffect(() => {
    if (!store.ready || !ongoing || prefilled.current.has(session.id)) return
    prefilled.current.add(session.id)
    const next = prefillEmptySession(session, hints)
    if (next !== session) store.put(next)
  }, [store.ready, ongoing, session, hints, store.put])

  useEffect(() => {
    if (!active) return
    setNow(Date.now())
    const timer = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(timer)
  }, [active])
  useBrowserLayoutEffect(()=>{if(visible)scrollToTop('auto')},[visible,selectedId,ongoing,section])
  useEffect(()=>{const back=()=>{if(openedFromRecords){setOpenedFromRecords(false);setSelectedId(null);window.requestAnimationFrame(()=>{const c=appRef.current?.closest('.health-page-content');if(c)c.scrollTop=recordsScroll.current})}};window.addEventListener('popstate',back);return()=>window.removeEventListener('popstate',back)},[openedFromRecords])
  useEffect(() => {
    if (!active) return
    const handler = e => { if (Object.values(store.records).some(r => r.dirty)) { e.preventDefault(); e.returnValue = '' } }
    window.addEventListener('beforeunload', handler)
    return () => window.removeEventListener('beforeunload', handler)
  }, [active, store.records])

  function begin(template = null) {
    setOpenedFromRecords(false)
    if (store.active) { setSelectedId(store.active.session.id); setExpanded(store.active.session.exercises.find(m => m.sets.some(s => !s.completed_at))?.id || store.active.session.exercises[0]?.id); scrollToTop(); return }
    const next = startSession(template, exercises, hints)
    store.put(next); setSelectedId(next.id); setExpanded(next.exercises[0]?.id || null); setMessage('')
    scrollToTop()
  }

  function openCompletedWorkout(id) {
    recordsScroll.current=appRef.current?.closest('.health-page-content')?.scrollTop||0
    window.history.pushState({...window.history.state,healthRecord:id},'',window.location.href)
    setOpenedFromRecords(true)
    setSelectedId(id)
    setExpanded(null)
    setMessage('')
  }
  function closeWorkout() {
    const returnToRecords=openedFromRecords
    const hasRecordEntry=returnToRecords&&window.history.state?.healthRecord
    setSelectedId(null)
    setMessage('')
    setOpenedFromRecords(false)
    setGroupOptions(null)
    if (returnToRecords) {
      if(active)onReturnToRecords?.()
      window.requestAnimationFrame(()=>{const content=appRef.current?.closest('.health-page-content');if(content)content.scrollTop=recordsScroll.current})
      // The UI closes synchronously, including WebViews where back() emits no event.
      if(hasRecordEntry)window.history.back()
    }
  }
  function scrollToTop(behavior = 'smooth') {
    const content = appRef.current?.closest('.health-page-content')
    if (content) {
      if (behavior === 'auto') content.scrollTop = 0
      else content.scrollTo({ top: 0, behavior })
    }
    window.scrollTo({ top: 0, behavior })
  }
  function update(edit) { const next = clone(session); edit(next); store.put(next); setMessage('') }
  function updateMovement(id, edit) { update(next => edit(next.exercises.find(m => m.id === id), next)) }
  function selectSet(movement, item, edited = false) {
    const key = `${session.id}:${movement.id}`
    setSetSources(old => ({ ...old, [key]: { ...old[key], selected: item.id, ...(edited ? { edited: item.id } : {}) } }))
    setFillNotice('')
  }
  function complete(movement, item) {
    if (session.paused_at) return
    if (!item.completed_at && !hasSetValue(movement, item)) {
      setMessage(isTimed(movement) ? '先填写这一组的秒数，再点完成。' : '先填写这一组的重量和次数，再点完成。'); return
    }
    updateMovement(movement.id, (next, doc) => {
      const row = next.sets.find(s => s.id === item.id)
      Object.assign(doc,toggleSet(session,movement.id,item.id))
    })
  }
  function field(movement, item, name, value) {
    const numeric = Number(value)
    if (value !== '' && (!Number.isFinite(numeric) || (name === 'weight' ? numeric < 0 || numeric > 2000 : !Number.isInteger(numeric) || numeric < 1 || numeric > (name === 'duration_seconds' ? 3600 : 1000)))) {
      setMessage(name === 'weight' ? '重量请填写 0–2000 之间的数值。' : name === 'duration_seconds' ? '秒数请填写 1–3600 之间的整数。' : '次数请填写 1–1000 之间的整数。'); return false
    }
    const nextValue = value === '' ? null : numeric
    if (item[name] === nextValue) { setMessage(''); return true }
    const key = `${session.id}:${movement.id}`
    const baselines = editBaselines.current[key] ||= {}
    baselines[item.id] ||= { weight: item.weight, reps: item.reps, duration_seconds: item.duration_seconds, unit: movement.unit }
    updateMovement(movement.id, next => {
      const row = next.sets.find(s => s.id === item.id)
      row[name] = nextValue
      if (row[name] == null || (name === 'reps' && !(row.reps >= 1))) row.completed_at = null
    })
    selectSet(movement, item, true)
    return true
  }
  function addExercise(exercise) {
    const movement = newMovement(exercise, {}, previousSets(hints, exercise.id, session.id, {
      before: session.started_at, timezone: session.timezone, loadMode: exercise.load_mode, allowSameDay: true,
    }))
    update(next => next.exercises.push(movement)); setExpanded(movement.id); setPicker(false)
  }
  function created(exercise) { store.setCatalog(old => ({ ...old, exercises: [...old.exercises, exercise] })) }
  function savedTemplate(saved) { store.setCatalog(old => ({ ...old, templates: [...old.templates.filter(r => r.template.id !== saved.template.id), saved] })) }
  function makeTemplate() {
    setEditing({ version: 0, template: { ...sessionTemplate(session), id: uid() } })
  }
  const blocked = Object.values(store.records).filter(r => r.blocked)
  const dirty = Object.values(store.records).some(r => r.dirty)
  const settings = session?.exercises.find(m => m.id === settingsId)
  const groupMovement=session?.exercises.find(m=>m.id===groupOptions?.movementId)
  function openGroup(movementId,setId){setGroupOptions({movementId,setId});setGroupHint(false);try{localStorage.setItem('health-set-options-used','1')}catch{}}
  const restSeconds = session?.rest_until ? Math.max(0, Math.ceil((new Date(session.rest_until) - new Date(session.paused_at || now)) / 1000)) : null
  const savedText = record?.blocked ? '同步需要处理' : record?.dirty ? '本机已保存 · 待同步' : '已保存到服务器'
  const focusedMovement = ongoing ? session.exercises.find(m => m.id === expanded)
    || session.exercises.find(m => m.sets.some(s => !s.completed_at)) || session.exercises[0] : null
  const focusedIndex = focusedMovement ? session.exercises.indexOf(focusedMovement) : -1
  const nextMovement = session?.exercises[focusedIndex + 1]
  const allSetsDone = Boolean(work?.planned && work.done === work.planned)
  const saveLabel = record?.blocked ? '同步异常' : record?.dirty ? '待同步' : '已保存'
  nativeState.current = { session, active:visible, selectedId, movement: focusedMovement, put: store.put, close: closeWorkout }
  useEffect(() => {
    setNativeScreen({ screen: visible&&session ? ongoing ? 'workout' : 'report' : 'home',
      title: ongoing ? session.title.trim() || '力量训练' : session ? '训练总结' : '训练', workoutID: session?.id || null })
  }, [setNativeScreen, session?.id, session?.title, ongoing,visible])

  async function nativeFinish(discard = false) {
    if (!nativeAlive.current) return
    const current = nativeState.current.session
    if (!current || current.status !== 'active') return
    if (!hasNativeCapability('menus-v1')) { setConfirm(discard ? 'discard' : 'finish'); return }
    try {
      const progress = summary(current)
      const result = await nativeRequest('presentConfirmation', { confirmation: {
        title: discard ? '放弃本次训练？' : '完成这场训练？',
        message: discard ? '本次训练将从训练列表移除。' : finishMessage(current),
        confirmLabel: discard ? '放弃训练' : '完成并保存', destructive: discard,
      } })
      const latest = nativeState.current.session
      if (nativeAlive.current && result?.confirmed && latest?.id === current.id && latest.status === 'active') {
        nativeState.current.put(finishSession(latest, discard ? 'discarded' : 'completed'))
        if (discard) setSelectedId(null)
      }
    } catch (error) { if (nativeAlive.current) setMessage(error.message) }
  }
  useEffect(() => {
    if (!hasNativeCapability('chrome-v1')) return
    nativeAlive.current = true
    const action = event => {
      const value = event.detail, current = nativeState.current
      if (!current.active || !current.session || (value?.sessionID && value.sessionID !== current.session.id)) return
      if (value?.type === 'back') { current.close(); return }
      if (current.session.status !== 'active') return
      if (value?.type === 'finishWorkout') nativeFinish()
      if (value?.type === 'discardWorkout') nativeFinish(true)
      if (value?.type === 'workoutNotes') setSessionTools('notes')
      if (value?.type === 'movementSettings' && current.movement) setSettingsId(current.movement.id)
      if (value?.type === 'renameWorkout' && typeof value.title === 'string' && value.title.trim() && value.title.length <= 100) {
        current.put({ ...current.session, title: value.title.trim() })
      }
    }
    window.addEventListener('health-native-action', action)
    return () => { nativeAlive.current = false; window.removeEventListener('health-native-action', action) }
  }, [])

  async function openMovementMenu() {
    if (!session.exercises.length) { setPicker(true); return }
    if (!hasNativeCapability('menus-v1')) { setExerciseMenu(true); return }
    const target = session.id
    try {
      const result = await nativeRequest('presentMenu', { menu: { title: '切换动作', actions: session.exercises.map((movement, index) => ({
        id: movement.id, title: `${index + 1}. ${movement.name} · ${movement.sets.filter(s => s.completed_at).length}/${movement.sets.length} 组`,
      })) } })
      const current = nativeState.current.session
      if (nativeAlive.current && current?.id === target && current.status === 'active' && current.exercises.some(m => m.id === result?.selected)) switchMovement(result.selected)
    } catch (error) { if (nativeAlive.current) setMessage(error.message) }
  }
  async function openMovementSettings(movement) {
    if (!hasNativeCapability('menus-v1')) { setSettingsId(movement.id); return }
    const target = session.id
    try {
      const result = await nativeRequest('presentMenu', { menu: { title: movement.name,
        actions: [{ id: 'edit', title: '动作设置' }, { id: 'history', title: '动作历史' }] } })
      const current = nativeState.current.session
      const latest = current?.exercises.find(m => m.id === movement.id)
      if (!nativeAlive.current || current?.id !== target || current.status !== 'active' || !latest) return
      if (result?.selected === 'edit') setSettingsId(latest.id)
      if (result?.selected === 'history') setExerciseHistory(latest)
    } catch (error) { if (nativeAlive.current) setMessage(error.message) }
  }
  function switchMovement(id) { setExpanded(id); setExerciseMenu(false); setMessage(''); scrollToTop() }
  function askDelete(id) { setDeleteError(null); setDeleteId(id) }
  async function removeHistory() {
    const targetId = deleteId
    try {
      await store.remove(targetId)
      const current = nativeState.current
      if (current.selectedId === targetId) current.close()
      setDeleteId(current => current === targetId ? null : current)
    } catch (error) { setDeleteError({ id: targetId, message: error.message || '删除失败，记录仍保留，请重试。' }) }
  }

  return <>
    <WorkoutRecords store={store} active={showRecords} visible={showRecords&&!recordView} onStart={()=>onOpenTraining?.()} onOpenTraining={openCompletedWorkout} />
    <div hidden={!visible} data-record-detail={recordView||undefined} ref={appRef} className={`strength-app ${session && active ? 'st-session-view' : ''} ${ongoing && active ? 'st-live-view' : ''}`}>
    {requestedError && <p className="st-notice" role="status">{requestedError}</p>}
    {(store.error || store.storageError) && <div className="st-notice" role="status"><span>{store.storageError || store.error}</span><button onClick={() => { store.refresh(); store.sync() }}>重试</button></div>}
    {blocked.map(r => <div className="st-notice st-conflict" role="alert" key={r.session.id}>
      <strong>{r.session.title}</strong><span>{r.blocked.message}</span>
      <div><button onClick={() => { setSelectedId(r.session.id); if (r.blocked.status === 422) store.resolve(r.session.id, true) }}>查看本机记录</button>
        {r.blocked.server && <><button onClick={() => store.resolve(r.session.id, true)}>使用本机版本</button><button onClick={() => store.resolve(r.session.id, false)}>使用服务器版本</button></>}
        {!r.blocked.server && r.blocked.status === 409 && <button onClick={() => { store.resolve(r.session.id, true); store.refresh() }}>重新检查</button>}</div>
    </div>)}

    {!session ? <>

      {store.active && <button className="st-resume" onClick={() => begin()}><span className="st-live-dot" /><span><strong>继续训练</strong><small>{store.active.session.title} · {store.active.session.paused_at?'已暂停':'进行中'} · {clockText(elapsedSeconds(store.active.session))}</small></span><Icon name="arrow" /></button>}
      <TrainingRound active={active} changed={store.records} onData={setRoundData} onTraining={request=>{
        if(request?.session_id){setSelectedId(request.session_id);store.load(request.session_id).catch(()=>setMessage('暂时无法打开训练记录，请重试。'))}
        else if(store.active)setSelectedId(store.active.session.id)
        else if(request?.template_id){
          const found=templates.find(r=>r.template.id===request.template_id)?.template
          if(found){const pending=new Map((request.remaining||[]).map(m=>[m.exercise_id,m.target]));setPreviewTemplate(pending.size?{...found,exercises:found.exercises.filter(m=>pending.has(m.exercise_id)).map(m=>pending.get(m.exercise_id)>=m.set_count-(m.warmup_count||0)?m:remainingPlan(m,pending.get(m.exercise_id)))}:found)}
        }
      }}/>
      {store.loading && !store.catalog ? <div className="st-empty">正在载入模板…</div> : !store.catalog ? <div className="st-empty">暂时无法载入动作与模板。<button className="st-text-button" onClick={store.refresh}>重新载入</button></div> : <>
        <TemplateLibrary templates={templates} exercises={exercises} routine={routine} disabled={Boolean(store.active)}
          onPreview={setPreviewTemplate} onEdit={setEditing} onStart={begin} />
        <details className="st-weekly-overview"><summary>本周训练概览</summary><TrainingFocus history={hints} catalog={exercises} round={roundData?.plan}/><WeeklyTraining history={hints} catalog={exercises} now={new Date(now)} /></details>
      </>}
      <button className="st-text-button st-free-training" disabled={Boolean(store.active) || !store.catalog} onClick={() => begin()}><Icon name="plus" size={15} /> 自由训练</button>
      <p className="st-footer-note">{store.syncing ? '正在保存…' : dirty ? '本机记录已保留，等待同步' : '训练记录会自动保存'}</p>
    </> : <>
      {!ongoing && <button className="st-back" onClick={closeWorkout}><Icon name="back" size={16} /> {openedFromRecords ? '返回运动记录' : '返回训练'}</button>}
      {ongoing ? <>
        <TrainingToolbar active={active}><header className="st-session-toolbar" aria-label="正在进行的训练">
          <div className="st-live-topline">
            <button className="st-icon-button st-leave" title="返回模板，训练记录会保留" aria-label="返回模板，训练记录会保留" onClick={() => { setSelectedId(null); setMessage('') }}><Icon name="back" size={18} /></button>
            <div className="st-session-summary"><input className="st-session-title" aria-label="训练名称" maxLength={100} value={session.title} title={session.title} onChange={e => update(next => { next.title = e.target.value })} onBlur={() => { if (!session.title.trim()) update(next => { next.title = '力量训练' }) }} /></div>
            <button className="st-finish-button" onClick={() => nativeFinish()}>结束</button>
          </div>
          <div className="st-session-caption">
            <button className="st-icon-button st-pause" aria-label={session.paused_at ? '继续训练' : '暂停训练'} onClick={() => store.put(togglePause(session))}><Icon name={session.paused_at ? 'play' : 'pause'} size={14} /></button>
            <strong>{clockText(elapsedSeconds(session, now))}</strong>
            <span className="st-live-state">{session.paused_at ? '已暂停' : `${work.done} / ${work.planned} ${isPosture(session)?'练习组':'工作组'}${work.warmup?' · 热身 '+work.warmup+' 组':''}`}</span>
            <small className={`st-save-state ${record.dirty ? 'pending' : ''}`} title={savedText} aria-label={savedText}><i />{saveLabel}</small>
          </div>
          <div className="st-progress-track" aria-label={`已完成${work.done}个工作组，共${work.planned}组`}><span style={{ width: `${work.planned ? work.done / work.planned * 100 : 0}%` }} /></div>
        </header></TrainingToolbar>
        {message && <p className="st-error st-validation" role="alert">{message}</p>}
        <div className="st-workout-navigation"><button className="st-exercise-switch" aria-haspopup="dialog" onClick={openMovementMenu}><Icon name="list" size={17} /> 切换动作 <span>{focusedMovement ? focusedIndex + 1 : 0} / {session.exercises.length}</span><Icon name="down" size={14} /></button><button className="st-add-action" disabled={session.exercises.length >= 40} onClick={() => setPicker(true)}><Icon name="plus" size={15} /> 添加动作</button></div>
        <div className="st-exercise-stack">{(focusedMovement ? [focusedMovement] : []).map(movement => {
          const done = movement.sets.filter(s => s.completed_at).length
          const nextSet = movement.sets.findIndex(s => !s.completed_at)
          const movementKey = `${session.id}:${movement.id}`
          const sources = setSources[movementKey]
          const source = movement.sets.find(item => item.id === sources?.selected) || movement.sets[nextSet] || movement.sets.at(-1)
          const sourceIndex = movement.sets.indexOf(source)
          const followingSets = movement.sets.slice(sourceIndex + 1).filter(item => !item.completed_at)
          const following = followingSets.length
          const timed = isTimed(movement)
          const noWeight = timed || (movement.training_type === 'mobility' && movement.load_mode === 'bodyweight')
          const canFill = hasSetValue(movement, source)
          const baseline = editBaselines.current[movementKey]?.[source?.id]
          const baselineWeight = baseline && (baseline.unit === movement.unit
            ? baseline.weight : convertWeight(baseline.weight, baseline.unit, movement.unit))
          const changed = baseline && (setValue(movement, source) !== setValue(movement, baseline)
            || source.weight !== baselineWeight)
          const showFill = canFill && changed && followingSets.some(item => setValue(movement, item) !== setValue(movement, source)
            || (movement.load_mode !== 'bodyweight' && item.weight !== source.weight))
          const previous = previousSets(sameContext(hints,session,movement), movement.exercise_id, session.id, { before: session.started_at, timezone: session.timezone, loadMode: movement.load_mode, allowSameDay: true })
          return <article className="st-exercise-card open" key={movement.id} aria-label={`当前动作：${movement.name}`}>
            <div className="st-exercise-heading"><span className="st-exercise-number">{String(focusedIndex + 1).padStart(2, '0')}</span><div className="st-current-exercise-name"><h2>{movement.name}</h2><p>{done === movement.sets.length ? '全部完成' : `工作组 ${movement.sets.filter(s=>!s.warmup&&s.completed_at).length} / ${movement.sets.filter(s=>!s.warmup).length}${movement.sets.some(s=>s.warmup)?' · 含热身 '+movement.sets.filter(s=>s.warmup).length+' 组':''}`}{movement.load_mode === 'assistance' ? ' · 辅助重量' : ''}</p></div><button className="st-icon-button st-more" aria-label={`设置${movement.name}`} onClick={() => openMovementSettings(movement)}>···</button></div>
            <div className="st-exercise-body">
              {movement.training_type === 'mobility' && <p className="st-mobility-hint">{exercises.find(e => e.id === movement.exercise_id)?.instructions?.at(-1)}</p>}
              {(movement.weight_note||exercises.find(e=>e.id===movement.exercise_id)?.weight_note)&&<p className="st-load-note">{movement.weight_note||exercises.find(e=>e.id===movement.exercise_id)?.weight_note}</p>}
              {previous.length>0&&<p className="st-last-performance">上次 · {lastPerformance(previous,movement)}</p>}
              <PrescriptionHint movement={movement} history={hints} session={session} onApply={value => updateMovement(movement.id, next => Object.assign(next, adoptPrescription(next, value)))} />
              <div className={`st-set-grid st-set-labels ${noWeight ? 'is-timed' : ''}`}><span>组次</span>{!noWeight && <span>{movement.load_mode === 'assistance' ? '辅助' : '重量'} / {weightUnitLabel(movement.unit)}</span>}<span>{timed ? '时长 / 秒' : '次数'}</span><span>完成</span></div>
              {movement.sets.map((item, si) => <div className={`st-set-grid st-set-row ${noWeight ? 'is-timed' : ''} ${item.completed_at ? 'done' : si === nextSet ? 'current' : ''}`} key={item.id}>
                <SetNumber movement={movement} index={si} onClick={()=>openGroup(movement.id,item.id)}/>
                {!noWeight && <TrainingNumberInput aria-label={`${movement.name}第${si + 1}组${movement.load_mode === 'assistance' ? '辅助重量' : '重量'} ${weightUnitLabel(movement.unit)}`} decimal enterKeyHint="next" placeholder={movement.load_mode === 'bodyweight' ? '自重' : '—'} disabled={movement.load_mode === 'bodyweight'} value={item.weight} onActivate={() => selectSet(movement, item)} onValueChange={value => field(movement, item, 'weight', value)} />}
                <TrainingNumberInput aria-label={`${movement.name}第${si + 1}组${timed ? '时长 秒' : '次数'}`} enterKeyHint="done" placeholder="—" value={setValue(movement, item)} onActivate={() => selectSet(movement, item)} onValueChange={value => field(movement, item, timed ? 'duration_seconds' : 'reps', value)} />
                <button className="st-check" disabled={Boolean(session.paused_at)} aria-label={`${item.completed_at ? '撤销' : '完成'}${movement.name}第${si + 1}组`} aria-pressed={Boolean(item.completed_at)} onClick={() => complete(movement, item)}><Icon name={item.completed_at ? 'check' : 'circle'} size={22} /></button>
              </div>)}
              {feedbackSummary(movement)&&<p className="st-set-feedback-summary">{feedbackSummary(movement)}</p>}
              {groupHint&&<p className="st-set-options-hint">点组号，可记录吃力次数或删除本组。</p>}
              {showFill && <div className="st-fill-following"><span><strong>第 {sourceIndex + 1} 组</strong><small>{timed ? `${source.duration_seconds} 秒` : `${movement.load_mode === 'bodyweight' ? '自重' : `${source.weight} ${weightUnitLabel(movement.unit)}`} × ${source.reps} 次`}</small></span><button title="复制重量和次数，保留已完成记录和热身标记" onClick={() => {
                updateMovement(movement.id, next => { next.sets = fillFollowingSets(next, source.id).sets })
                delete editBaselines.current[movementKey][source.id]
                selectSet(movement, source, true)
                setFillNotice(`已将第 ${sourceIndex + 1} 组数值应用到后续 ${following} 个未完成组`)
              }}><Icon name="fill" size={15} /> 应用到后续 {following} 组</button></div>}
              <span className="sr-only" role="status">{fillNotice}</span>
              <div className="st-exercise-bottom"><button className="st-inline-action" disabled={movement.sets.length >= 50} onClick={() => {
                const next = appendExerciseSet(movement, sources?.edited)
                updateMovement(movement.id, item => { item.sets = next.sets })
                selectSet(movement, next.sets.at(-1), true)
              }}><Icon name="plus" size={15} /> 新增一组</button><button className="st-inline-action" onClick={() => setExerciseHistory({ ...exercises.find(e => e.id === movement.exercise_id), ...movement,initialTab:previous.length?'progress':'guide',template_id:session.template_id })}><Icon name="clock" size={14} />{previous.length ? `上次 ${dateText(previous[0].date)}` : '动作说明'}</button></div>
              {session.rest_until ? <aside className={`st-rest-inline ${restSeconds ? '' : 'ready'}`} aria-label="组间休息"><span className="st-rest-orbit"><Icon name={restSeconds ? 'clock' : 'check'} size={18} /></span><div><small>{session.paused_at?'休息已暂停':restSeconds?(session.exercises.some(m=>m.sets.some(s=>s.id===session.rest_set_id&&s.warmup))?'热身休息':'组间休息'):'休息结束'}</small><strong>{restSeconds ? clockText(restSeconds) : '准备下一组'}</strong></div>{restSeconds>0&&<button disabled={Boolean(session.paused_at)} onClick={()=>update(next=>{next.rest_until=new Date(Date.parse(next.rest_until)+30000).toISOString()})}>＋30秒</button>}<button onClick={() => update(next => { next.rest_until = null;next.rest_set_id=null })}>{restSeconds ? '跳过' : '收起'}</button></aside> : <button className="st-rest-idle" onClick={() => setSettingsId(movement.id)}><Icon name="clock" size={14} /><span>组间休息</span><b>{movement.rest_seconds ? clockText(movement.rest_seconds) : '已关闭'}</b><Icon name="arrow" size={12} /></button>}
            </div>
          </article>
        })}</div>
        {focusedMovement ? <div className="st-action-navigation"><button className="st-previous-action" aria-label="上一个动作" disabled={focusedIndex === 0} onClick={() => switchMovement(session.exercises[focusedIndex - 1].id)}><Icon name="back" size={18} /></button><button className={`st-next-action ${focusedMovement.sets.every(s => s.completed_at) ? 'ready' : ''}`} onClick={() => allSetsDone ? nativeFinish() : nextMovement ? switchMovement(nextMovement.id) : openMovementMenu()}><span><small>{allSetsDone ? '所有组次已完成' : nextMovement ? '下一个动作' : '本次训练'}</small><strong>{allSetsDone ? '结束训练，查看报告' : nextMovement ? nextMovement.name : '查看全部动作'}</strong></span><Icon name="arrow" size={17} /></button></div> : <div className="st-empty"><strong>开始你的第一个动作</strong><button className="st-primary" onClick={() => setPicker(true)}><Icon name="plus" size={17} /> 添加动作</button></div>}
        <div className="st-session-tools" role="group" aria-label="训练附加操作">
          <button aria-haspopup="dialog" onClick={() => setSessionTools('notes')}><Icon name="edit" size={14} />训练笔记{session.notes.trim() && <i className="st-note-dot" aria-label="已有笔记" />}</button>
          <button aria-haspopup="dialog" onClick={() => setSessionTools('more')}><span className="st-tool-ellipsis" aria-hidden="true">···</span>更多操作</button>
        </div>
      </> : <TrainingReport session={session} history={hints} catalog={exercises} savedText={savedText} canRepeat={!store.active} serverSaved={!record.dirty && !record.blocked} visible={visible}
        onEdit={()=>setCorrection(session)}
        onExercise={movement => setExerciseHistory({ ...exercises.find(e => e.id === movement.exercise_id), ...movement,template_id:session.template_id })}
        onDelete={() => askDelete(session.id)}
        onSetOptions={openGroup}
        onSaveTemplate={makeTemplate}
        onRepeat={() => begin(sessionTemplate(session))} />}
    </>}

    {sessionTools && ongoing && active && <Modal title={sessionTools === 'notes' ? '训练笔记' : '更多操作'} onClose={() => setSessionTools(null)}>
      {sessionTools === 'notes' ? <>
        <label className="st-notes st-session-note">笔记<textarea aria-label="训练笔记" placeholder="记下今天的感受、器械设置…" maxLength={4000} value={session.notes} onChange={e => update(next => { next.notes = e.target.value })} /></label>
        <button className="st-primary st-wide" onClick={() => setSessionTools(null)}>完成</button>
      </> : <button className="st-danger st-wide" onClick={() => { setSessionTools(null); setConfirm('discard') }}>放弃本次训练</button>}
    </Modal>}
    {exerciseMenu && ongoing && <Modal title="本次动作" onClose={() => setExerciseMenu(false)}>
      <div className="st-exercise-menu">{session.exercises.map((movement, index) => { const completed = movement.sets.filter(s => s.completed_at).length; return <button key={movement.id} aria-current={focusedMovement?.id === movement.id ? 'true' : undefined} onClick={() => switchMovement(movement.id)}><span className="st-menu-number">{completed === movement.sets.length ? <Icon name="check" size={16} /> : index + 1}</span><span><strong>{movement.name}</strong><small>{completed} / {movement.sets.length} 组</small></span><Icon name="arrow" size={15} /></button> })}</div>
      <button className="st-secondary st-wide" disabled={session.exercises.length >= 40} onClick={() => { setExerciseMenu(false); setPicker(true) }}><Icon name="plus" size={17} /> 添加动作</button>
    </Modal>}
    {picker && <ExercisePicker exercises={exercises} onPick={exercise => { if (picker === 'library') { setExerciseHistory({ ...exercise, exercise_id: exercise.id }); setPicker(false) } else if(replaceId){const old=session.exercises.find(m=>m.id===replaceId);const pending=old?.sets.filter(s=>!s.completed_at)||[];if(pending.length){const replacement=replacementMovement(exercise,old);update(next=>{const i=next.exercises.findIndex(m=>m.id===replaceId);const finished=next.exercises[i].sets.filter(s=>s.completed_at);if(finished.length){next.exercises[i].sets=finished;next.exercises.splice(i+1,0,replacement)}else next.exercises.splice(i,1,replacement)});setExpanded(replacement.id)}setReplaceId(null);setPicker(false)}else addExercise(exercise) }} onCreated={created} onClose={() => {setPicker(false);setReplaceId(null)}} />}
    {previewTemplate && <Modal title={previewTemplate.name} onClose={() => setPreviewTemplate(null)}>
      {previewTemplate.duration_min && <p className="st-muted">预计 {previewTemplate.duration_min}–{previewTemplate.duration_max} 分钟 · {previewTemplate.id.startsWith('posture-') ? `${templateCounts(previewTemplate).total} 组` : `${templateCounts(previewTemplate).work} 个工作组 + ${templateCounts(previewTemplate).warmup} 个热身组`}</p>}
      {previewTemplate.description && <p className="st-template-description">{previewTemplate.description}</p>}
      <ol className="st-template-moves">{previewTemplate.exercises.map((plan, i) => <li key={`${plan.exercise_id}-${i}`}><span className="st-index">{i + 1}</span><span>{exercises.find(e => e.id === plan.exercise_id)?.name || '动作'}{plan.set_targets && <small className="st-preset-preview">{targetLabel(plan)} · 休息 {plan.rest_seconds} 秒</small>}</span><b>{plan.set_count - (plan.warmup_count || 0)}<small> {plan.warmup_count != null && !previewTemplate.id.startsWith('posture-') ? '工作组' : '组'}{plan.warmup_count > 0 && ` + ${plan.warmup_count} 热身`}{plan.set_targets?'':plan.target_seconds ? ` × ${plan.target_seconds}秒` : plan.target_reps ? ` × ${plan.target_reps}次` : ''}</small></b></li>)}</ol>
      {previewTemplate.notes && <details className="st-template-extra"><summary>训练说明</summary><p className="st-program-notes">{previewTemplate.notes}</p></details>}
      {!previewTemplate.id.startsWith('posture-') && <details className="st-template-extra"><summary>肌群与进阶建议</summary>
      <BodyMap load={templateMuscles(previewTemplate, exercises)} label="模板计划肌群" />
      {previewTemplate.exercises.map((plan, index) => {
        const exercise = exercises.find(e => e.id === plan.exercise_id)
        const before = new Date(now).toISOString()
        const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone
        const scoped = targetHistory(hints, previewTemplate.id, plan.set_targets ? plan.targets_updated_at : null)
        const previous = previousSets(scoped, plan.exercise_id, null, { before, timezone, loadMode: exercise?.load_mode, allowSameDay: true })
        const workSets = plan.set_count - (plan.warmup_count ?? previous.slice(0, plan.set_count).filter(s => s.warmup).length)
        const advice = plan.set_targets && !previous.some(s => !s.warmup) ? null : nextPrescription({ ...plan, load_mode: exercise?.load_mode, work_sets: workSets }, scoped, { before, timezone })
        return <div className="st-template-targets" key={`${plan.exercise_id}-${index}`}><strong>{exercise?.name} · {plan.progression === 'double' ? '双重进阶' : '进阶参考'}</strong>
          <small>{advice ? prescriptionLabel(advice, exercise?.load_mode, plan.unit) : targetLabel(plan)}</small><p>{advice?.reason || (plan.set_targets ? '按预设建立本轮基线，多数正式组保留约2次余力。' : '热身组不参与进阶。')}</p></div>
      })}
      <p className="st-muted">参考目标可以在编辑模板时配置；启用双重进阶后，新训练会自动填入建议。</p>
      </details>}
      <button className="st-primary st-wide" disabled={Boolean(store.active)} onClick={() => { const template = previewTemplate; setPreviewTemplate(null); begin(template) }}><Icon name="play" size={17} /> 开始训练</button>
    </Modal>}
    {correction&&<RecordCorrection session={correction} onClose={()=>setCorrection(null)} onSave={value=>{store.put(value);setCorrection(null)}}/>}
    {editing && <TemplateEditor record={editing} exercises={exercises} onSave={savedTemplate} onClose={() => setEditing(null)} />}
    {exerciseHistory && <ExerciseProgress key={exerciseHistory.exercise_id || exerciseHistory.id} exercise={exerciseHistory} history={hints} deletedIds={store.deletedIds} onClose={() => setExerciseHistory(null)} />}
    {groupMovement&&groupMovement.sets.some(s=>s.id===groupOptions.setId)&&<SetOptions key={`${session.id}:${groupOptions.setId}`} movement={groupMovement} setId={groupOptions.setId} onClose={()=>setGroupOptions(null)} onSave={value=>{updateMovement(groupMovement.id,next=>{next.sets.find(s=>s.id===groupOptions.setId).hard_reps=value});setGroupOptions(null)}} onDelete={()=>{store.put(removeSessionSet(session,groupMovement.id,groupOptions.setId));setGroupOptions(null)}}/>}
    {settings && <Modal title={settings.name} onClose={() => setSettingsId(null)}>
      <div className="st-settings">
        <fieldset className="st-effort-settings"><legend>体感反馈（可选）</legend><div className="st-effort">{(settings.training_type==='mobility'?[['easy','舒适'],['normal','有点紧'],['hard','不适']]:[['easy', '简单'], ['normal', '正常'], ['hard', '困难']]).map(([value, label]) => <button key={value} aria-pressed={settings.effort === value} className={`st-effort-${value}`} onClick={() => updateMovement(settings.id, next => { next.effort = next.effort === value ? null : value })}><span />{label}</button>)}</div></fieldset>
        {settings.load_mode !== 'bodyweight' && <label>重量单位<select value={settings.unit} onChange={e => updateMovement(settings.id, next => {
          next.sets.forEach(s => { s.weight = convertWeight(s.weight, next.unit, e.target.value) })
          if (next.prescription) {
            next.prescription.weight = convertWeight(next.prescription.weight, next.unit, e.target.value)
            next.prescription.increment = Math.max(0.01, convertWeight(next.prescription.increment, next.unit, e.target.value))
          }
          next.unit = e.target.value
        })}><option value="lb">磅</option><option value="kg">公斤</option></select></label>}
        {settings.load_mode!=='bodyweight'&&<label>记重说明<input maxLength={200} placeholder="例如：每只哑铃；沿用现有记重方式" value={settings.weight_note||''} onChange={e=>updateMovement(settings.id,next=>{next.weight_note=e.target.value})}/></label>}
        <div>
          <label htmlFor="st-rest-seconds">组间休息 / 秒</label>
          <TrainingNumberInput key={settings.id} id="st-rest-seconds" aria-describedby="st-rest-hint" value={settings.rest_seconds}
            onValueChange={value => {
              if (value === '') return
              const seconds = Number(value)
              if (seconds > 600) return false
              if (seconds !== settings.rest_seconds) updateMovement(settings.id, next => { next.rest_seconds = seconds })
            }} />
          <p className="st-rest-hint" id="st-rest-hint">正式组 0–600 秒；热身最多 60 秒。填 0 关闭自动计时。</p>
        </div>
        <div className="st-inline-add"><button className="st-secondary" disabled={session.exercises[0].id === settings.id} onClick={() => update(next => { const i = next.exercises.findIndex(m => m.id === settings.id); [next.exercises[i - 1], next.exercises[i]] = [next.exercises[i], next.exercises[i - 1]] })}>↑ 上移</button><button className="st-secondary" disabled={session.exercises.at(-1).id === settings.id} onClick={() => update(next => { const i = next.exercises.findIndex(m => m.id === settings.id); [next.exercises[i + 1], next.exercises[i]] = [next.exercises[i], next.exercises[i + 1]] })}>↓ 下移</button></div>
        <button className="st-secondary" onClick={()=>{setReplaceId(settings.id);setSettingsId(null);setPicker(true)}}>替换剩余动作</button>
        <div className="st-set-types"><p>组次类型</p>{settings.sets.map((row,i)=><button className="st-secondary" key={row.id} onClick={()=>updateMovement(settings.id,next=>{next.sets[i].warmup=!row.warmup})}>{setLabel(settings,i)} · {row.warmup?'改为工作组':'改为热身'}</button>)}</div>
        <button className="st-danger" onClick={() => { setConfirm({ movement: settings.id }); setSettingsId(null) }}>移除动作</button>
      </div>
    </Modal>}
    {deleteRecord && <Modal title="删除这场训练？" onClose={() => setDeleteId(null)}>
      <p className="st-confirm-text"><strong>{deleteRecord.session.title}</strong><br />{dateText(deleteRecord.session.started_at, true)}<br />删除后会移除训练及心率报告，也不再用于历史对比。</p>
      {(deleteRecord.dirty || deleteRecord.blocked) && <p className="st-confirm-text">请先完成这条记录的同步，再删除。</p>}
      {deleteError?.id === deleteId && <p className="st-confirm-text" role="alert">{deleteError.message}</p>}
      {store.deleting && <p className="st-muted">可先关闭，删除结果会自动更新。</p>}
      <div className="st-confirm-buttons"><button className="st-secondary" onClick={() => setDeleteId(null)}>{store.deleting ? '关闭' : '取消'}</button><button className="st-danger" disabled={Boolean(store.deleting) || deleteRecord.dirty || Boolean(deleteRecord.blocked)} onClick={removeHistory}>{store.deleting ? '删除中…' : '确认删除'}</button></div>
    </Modal>}
    {confirm && <Modal title={confirm === 'finish' ? '完成这场训练？' : confirm === 'discard' ? '放弃本次训练？' : '移除这条记录？'} onClose={() => setConfirm(null)}>
      <p className="st-confirm-text">{confirm === 'finish' ? finishMessage(session) : confirm === 'discard' ? '本次训练会从训练列表中移除。' : '该动作或组次中的已完成数据也会从本次训练中移除。'}</p>
      <div className="st-confirm-buttons"><button className="st-secondary" onClick={() => setConfirm(null)}>继续记录</button><button className={confirm === 'finish' ? 'st-primary' : 'st-danger'} onClick={() => {
        if (confirm === 'finish' || confirm === 'discard') {
          store.put(finishSession(session, confirm === 'finish' ? 'completed' : 'discarded'))
          if (confirm === 'discard') setSelectedId(null)
        } else update(next => {
          if (confirm.set) Object.assign(next,removeSessionSet(next,confirm.movement,confirm.set))
          else {const removed=next.exercises.find(m=>m.id===confirm.movement);if(removed?.sets.some(s=>s.id===next.rest_set_id)){next.rest_set_id=null;next.rest_until=null}next.exercises=next.exercises.filter(m=>m.id!==confirm.movement)}
        })
        setConfirm(null)
      }}>{confirm === 'finish' ? '完成并保存' : '确认移除'}</button></div>
    </Modal>}
    </div>
  </>
}
