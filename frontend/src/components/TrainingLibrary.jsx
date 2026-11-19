import { useMemo, useState } from 'react'
import BODY_PATHS from '../training/vendor/body-paths.js'
import { MUSCLE_NAMES, MUSCLE_IDS, INERT_PARTS, muscleGroups, weeklyMuscles } from '../training/muscles.js'
import { movementPrescription, prescriptionLabel } from '../training/progression.js'
import '../training/library.css'
import {actualTargets,sameContext} from '../training/ux'

export function BodyMap({ load = {}, compact = false, label = '肌群训练分布' }) {
  const max = Math.max(1, ...Object.values(load))
  return <div className={`st-body-map${compact ? ' compact' : ''}`} role="group" aria-label={label}>
    {['front', 'back'].map(side => {
      const view = BODY_PATHS.male[side]
      return <svg key={side} viewBox={view.vb} role="img" aria-label={`${side === 'front' ? '正面' : '背面'}肌群示意`}>
        {INERT_PARTS.flatMap(id => (view.p[id] || []).map((d, i) => <path key={`${id}-${i}`} d={d} className="st-body-inert" />))}
        {MUSCLE_IDS.flatMap(id => (view.p[id] || []).map((d, i) => <path key={`${id}-${i}`} d={d}
          className={`st-body-muscle level-${load[id] > 0 ? Math.max(1, Math.ceil(load[id] / max * 4)) : 0}`}>
          <title>{`${MUSCLE_NAMES[id]}${load[id]>0?' · '+load[id]+' 组':''}`}</title>
        </path>))}
      </svg>
    })}
  </div>
}

export function ExerciseContent({ exercise }) {
  const groups = muscleGroups(exercise)
  const load = Object.fromEntries(groups.primary.map(id => [id, 1]))
  return <div className="st-exercise-guide">
    <div className="st-guide-overview"><BodyMap load={load} compact label="动作主要肌群" /><div>
      {exercise.english_name && <p className="st-guide-english">{exercise.english_name}</p>}
      <p>{exercise.description || '自定义动作'}</p><p className="st-muted">{exercise.equipment || '器械未填写'}</p>
    </div></div>
    <dl className="st-guide-muscles"><div><dt>主要肌群</dt><dd>{groups.primary.map(id => MUSCLE_NAMES[id]).join('、') || '尚未标注'}</dd></div>
      {groups.secondary.length > 0 && <div><dt>协同肌群</dt><dd>{groups.secondary.map(id => MUSCLE_NAMES[id]).join('、')}</dd></div>}</dl>
    {exercise.instructions?.length > 0 && <><h3>动作要点</h3><ol>{exercise.instructions.map((step, i) => <li key={i}>{step}</li>)}</ol></>}
    {exercise.weight_note && <p className="st-guide-weight">记重方式 · {exercise.weight_note}</p>}
  </div>
}

const normalize = value => String(value || '').normalize('NFKC').toLowerCase().replace(/\s+/g, '')
export function filterExercises(exercises, query = '', muscle = '', equipment = '') {
  const terms = query.trim().split(/\s+/).filter(Boolean).map(normalize)
  return exercises.filter(e => {
    const groups = muscleGroups(e)
    const text = normalize([e.name, e.english_name, ...(e.aliases || []), ...(e.muscles || []), e.equipment,
      ...[...groups.primary, ...groups.secondary].map(id => MUSCLE_NAMES[id])].join(' '))
    return terms.every(term => text.includes(term)) && (!muscle || groups.primary.includes(muscle) || groups.secondary.includes(muscle))
      && (!equipment || e.equipment === equipment)
  })
}

export function ExerciseBrowser({ exercises, onPick, onInfo, picking = false }) {
  const [query, setQuery] = useState(''), [muscle, setMuscle] = useState(''), [equipment, setEquipment] = useState('')
  const found = useMemo(() => filterExercises(exercises, query, muscle, equipment), [exercises, query, muscle, equipment])
  const equipmentList = [...new Set(exercises.map(e => e.equipment).filter(Boolean))]
  return <section className="st-exercise-browser" aria-label="动作筛选">
    <input className="st-search" aria-label="搜索动作" placeholder="搜索中文、英文、肌群或器械" maxLength={100} value={query} onChange={e => setQuery(e.target.value)} />
    <div className="st-library-filters"><label><span className="sr-only">筛选肌群</span><select aria-label="筛选肌群" value={muscle} onChange={e => setMuscle(e.target.value)}><option value="">全部肌群</option>{MUSCLE_IDS.map(id => <option key={id} value={id}>{MUSCLE_NAMES[id]}</option>)}</select></label>
      <label><span className="sr-only">筛选器械</span><select aria-label="筛选器械" value={equipment} onChange={e => setEquipment(e.target.value)}><option value="">全部器械</option>{equipmentList.map(eq => <option key={eq}>{eq}</option>)}</select></label></div>
    <p className="st-library-count" role="status">{found.length} 个动作{found.length !== exercises.length && ` / 共 ${exercises.length} 个`}</p>
    <div className={`st-library-results ${picking ? 'picking' : ''}`}>{found.map(exercise => <div className="st-library-result" key={exercise.id}>
      <button className="st-library-select" onClick={() => onPick(exercise)}><strong>{exercise.name}</strong><small>{exercise.equipment} · {exercise.muscles?.join(' / ') || '自定义'}</small><span>{picking ? '添加 +' : '说明与记录 ↗'}</span></button>
      {picking && onInfo && <button className="st-library-info" aria-label={`查看${exercise.name}说明`} onClick={() => onInfo(exercise)}>说明</button>}
    </div>)}</div>
    {!found.length && <p className="st-empty">没有匹配的动作，可调整筛选或创建自定义动作。</p>}
  </section>
}

export function WeeklyTraining({ history, catalog, now = new Date() }) {
  const date = now.toLocaleDateString('en-CA')
  const data = useMemo(() => weeklyMuscles(history, catalog, now), [history, catalog, date])
  const [all, setAll] = useState(false)
  const groups = [...data.groups].sort((a, b) => b.primary - a.primary || b.secondary - a.secondary)
  const shown = all ? groups : groups.filter(g => g.primary || g.secondary).slice(0, 6)
  const max = Math.max(1, ...groups.map(g => g.primary))
  return <section className="st-weekly-muscles" aria-label="本周肌群分布">
    <header><div><h3>本周肌群分布</h3><p>{data.start.slice(5).replace('-', '/')} – {data.end.slice(5).replace('-', '/')} · 周一开始</p></div><strong>{data.sets}<small> 工作组</small></strong></header>
    <div className="st-weekly-body"><BodyMap load={data.load} /><div className="st-muscle-bars">
      {!data.sets && <p className="st-muted">本周还没有完成的工作组。训练后会在这里显示。</p>}
      {shown.map(g => <div className="st-muscle-bar" key={g.id}><div><span>{g.name}</span><b>{g.primary}<small> 组</small></b></div><div className="st-muscle-track"><i style={{ width: `${g.primary / max * 100}%` }} /></div>{g.secondary > 0 && <small>另有 {g.secondary} 组协同参与</small>}</div>)}
      <button className="st-text-button" onClick={() => setAll(!all)}>{all ? '收起肌群' : '查看全部肌群'}</button>
    </div></div>
    <p className="st-muscle-method">只计已完成、非热身组。同一组可涉及多个肌群，协同组单列，颜色表示本周训练分布。{data.unknown > 0 && `另有 ${data.unknown} 个工作组尚未标注肌群。`}</p>
  </section>
}

export function PrescriptionHint({movement,history,session,onApply,next=false}) {
  const scoped=sameContext(history,session,movement)
  const prescription=next&&movement.prescription?movementPrescription(movement,[...scoped.filter(r=>r.session.id!==session.id),{session}],{before:new Date(Date.parse(session.ended_at)+1).toISOString(),timezone:session.timezone}):null
  if(next)return prescription?<details className="st-prescription"><summary><span>下次建议</span><strong>{prescriptionLabel(prescription,movement.load_mode,movement.unit)}</strong></summary><p>{prescription.reason}</p></details>:null
  return <details className="st-prescription st-actual-target"><summary><span>本次安排</span><strong>{actualTargets(movement)}</strong></summary><p>按逐组数值记录实际完成情况。{movement.prescription?.reason||''}</p></details>
}
