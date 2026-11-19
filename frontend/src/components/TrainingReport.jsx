import { useId } from 'react'
import { buildTrainingReport } from '../training/report'
import { clockText, weightUnitLabel } from '../training/strength'
import SessionReview from './SessionReview'
import useSessionReview from '../training/useSessionReview'
import { sessionReview } from '../training/review'
import { movementHeadlines } from '../training/conciseReview'
import { BodyMap, PrescriptionHint } from './TrainingLibrary'
import { muscleGroups } from '../training/muscles'
import '../training/report.css'
import {isPosture} from '../training/ux'
import {SetNumber} from './SetOptions'
import {validHardReps,acceptsFeedback} from '../training/setFeedback'

function dateLabel(value, timezone) {
  if (value.length === 10) return `${Number(value.slice(5, 7))}月${Number(value.slice(8, 10))}日`
  return new Intl.DateTimeFormat('zh-CN', { month: 'long', day: 'numeric', timeZone: timezone }).format(new Date(value))
}

function setResult(movement, set) {
  if (movement.tracking === 'duration') return `${set.duration_seconds} 秒`
  if (movement.load_mode === 'bodyweight') return `自重 × ${set.reps}`
  const assistance = movement.load_mode === 'assistance' ? '辅助 ' : ''
  return `${assistance}${set.weight} ${weightUnitLabel(movement.unit)} × ${set.reps}`
}

const representativeLabels = { external: '最重工作组', assistance: '最少辅助组', bodyweight: '最高次数' }

function SetPreview({ movement }) {
  const { load_mode: mode, representative: best } = movement
  if (!best) return <small>仅完成热身组</small>
  return <small><b>{setResult(movement, best)}</b> · {movement.tracking === 'duration' ? '单组时长' : representativeLabels[mode]}</small>
}

function RepChange({ movement }) {
  const comparison = movement.comparison
  if (!comparison?.repDelta) return null
  const basis = comparison.kind === 'bodyweight' ? '自重'
    : `${comparison.weight} ${weightUnitLabel(movement.unit)}${movement.load_mode === 'assistance' ? '辅助' : '同重组'}`
  const delta = comparison.repDelta
  return <span className="st-report-rep-change">{basis} · 较上次 {delta > 0 ? '+' : '−'}{Math.abs(delta)} 次</span>
}

function weightRange(values, unit) {
  if (!values.length) return '—'
  const low = Math.min(...values), high = Math.max(...values)
  return `${low === high ? low : `${low}–${high}`} ${weightUnitLabel(unit)}`
}

function Comparison({ movement, timezone }) {
  if (movement.training_type === 'mobility') return <p className="st-report-comparison st-muted">按实际完成记录，以舒适和稳定为先。</p>
  const comparison = movement.comparison
  if (!comparison) return <p className="st-report-comparison st-muted">{!movement.workSets ? '本次仅记录了热身组' : '暂无可比的历史工作组'}</p>
  const reference = dateLabel(comparison.date, timezone)
  const assistance = movement.load_mode === 'assistance'
  const identical = comparison.currentReps && JSON.stringify(comparison.currentReps) === JSON.stringify(comparison.previousReps)
  let detail
  if (comparison.kind === 'changed_load') {
    detail = `${assistance ? '辅助量' : '组次重量'} ${weightRange(comparison.previousWeights, movement.unit)} → ${weightRange(comparison.currentWeights, movement.unit)}`
  } else if (identical) {
    detail = `${comparison.kind === 'same_load' ? `${comparison.weight} ${weightUnitLabel(movement.unit)}${assistance ? ' 辅助量' : ' 同重量组'} · ` : ''}与上次记录一致`
  } else {
    const prefix = comparison.kind === 'same_load' ? `${comparison.weight} ${weightUnitLabel(movement.unit)}${assistance ? ' 辅助量' : ' 同重量组'} · ` : '自重组 · '
    detail = `${prefix}${comparison.previousReps.join(' / ')} → ${comparison.currentReps.join(' / ')} 次`
    if (comparison.repDelta != null && comparison.repDelta !== 0) detail += `（${comparison.repDelta > 0 ? '+' : '−'}${Math.abs(comparison.repDelta)}）`
    else if (comparison.repDelta == null) detail += '（组数不同）'
  }
  return <div className="st-report-comparison"><p>{detail}</p><small>对比 {reference}{comparison.converted ? ` · 已换算为 ${weightUnitLabel(movement.unit)}` : ''}</small></div>
}

export default function TrainingReport({ session, history, catalog = [], savedText, onRepeat, onSaveTemplate, canRepeat, onEdit, onDelete, onExercise, onSetOptions, serverSaved = true, visible = true }) {
  const reportId = useId()
  const posture=isPosture(session)
  const report = buildTrainingReport(session, history)
  const review = sessionReview(session, history)
  const aiReview = useSessionReview(session, serverSaved, visible)
  const headlines = movementHeadlines(session, history, aiReview.data?.evidence)
  const muscleTags = new Map(catalog.map(exercise => [exercise.id, exercise.muscles || []]))
  const muscles = [...new Set(report.movements.filter(movement => movement.workSets > 0)
    .flatMap(movement => muscleTags.get(movement.exercise_id) || []).map(tag => tag.trim()).filter(Boolean))]
  const muscleLoad = {}
  for (const movement of report.movements) {
    for (const id of muscleGroups(movement, catalog.find(e => e.id === movement.exercise_id)).primary) {
      muscleLoad[id] = (muscleLoad[id] || 0) + movement.workSets
    }
  }
  const movementId = movement => `${reportId}-${movement.id}`
  const startDate = dateLabel(session.started_at, session.timezone)
  const endDate = dateLabel(session.ended_at, session.timezone)
  const time = new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit', hour12: false, timeZone: session.timezone })
  return <section className="st-workout-report" aria-label="训练报告">
    <header className="st-report-overview">
      <h2>{session.title}</h2>
      <p className="st-report-date" title={session.timezone}>
        {startDate} · {time.format(new Date(session.started_at))} – {endDate !== startDate && `${endDate} `}{time.format(new Date(session.ended_at))}
      </p>
      <dl className="st-report-metrics" aria-label="训练概况">
        <div><dt>训练时长</dt><dd>{clockText(report.duration)}</dd></div>
        <div><dt>{posture?'练习组':'工作组'}</dt><dd>{review.completed}<small> / {review.planned}</small></dd></div>
        <div><dt>动作</dt><dd>{report.movements.length}<small> 个</small></dd></div>
      </dl>
      <div className="st-report-meta">
        <span>{report.warmupSets > 0 ? `热身 ${report.warmupSets} 组` : ''}</span>
        <span role="status" className={serverSaved ? 'st-report-saved' : undefined} aria-label={`训练已结束 · ${savedText}`}>{savedText}</span>
      </div>
      {muscles.length > 0 && <p className="st-report-muscles"><strong>训练部位</strong> <span>{muscles.join(' · ')}</span></p>}
      {report.workSets > 0 && <details className="st-report-muscle-details"><summary>训练详情与肌群</summary>
        <p>完成组数 {report.completed}/{report.planned}（含热身） · 总次数 {report.totalReps}{report.totalSeconds > 0 && ` · 拉伸 ${report.totalSeconds} 秒`}</p>
        {review.budget && <p>模板预计 {review.budget[0]}–{review.budget[1]} 分钟</p>}
        <BodyMap load={muscleLoad} compact label="本次已完成工作组肌群" />
      </details>}
    </header>

    <SessionReview session={session} history={history} reviewState={aiReview} />
    <section className="st-report-exercises" aria-label="动作记录">
      <header><h3>动作表现</h3><span>点开查看依据与组次</span></header>
      {!report.completed && <p className="st-report-empty">本次没有完成组次。</p>}
      {report.movements.map(movement => <details key={movement.id} id={movementId(movement)} className="st-report-movement">
        <summary className="st-report-disclosure">
          <span className="st-report-movement-title"><strong>{movement.name}</strong><small className="st-movement-headline">{headlines.get(movement.id)}</small></span>
          <span className="st-report-movement-count">{movement.workSets}/{movement.plannedWorkSets} 组</span>
        </summary>
        <div className="st-report-set-details">
          {movement.weight_note&&<p className="st-muted">{movement.weight_note}</p>}
          <SetPreview movement={movement} />
          <RepChange movement={movement} />
          <Comparison movement={movement} timezone={session.timezone} />
          {onExercise && <button className="st-text-button" onClick={() => onExercise(movement)}>查看长期进步 ↗</button>}
          <PrescriptionHint movement={movement} history={history} session={session} next />
          <table aria-label={`${movement.name}逐组记录`}><thead><tr><th>组次</th>{movement.tracking !== 'duration' && <th>{movement.load_mode === 'assistance' ? '辅助量' : '重量'}</th>}<th>{movement.tracking === 'duration' ? '时长 / 秒' : '次数'}</th></tr></thead>
            <tbody>{movement.sets.map(item => <tr key={item.id}><td>{onSetOptions?<SetNumber movement={session.exercises.find(m=>m.id===movement.id)} index={session.exercises.find(m=>m.id===movement.id).sets.findIndex(s=>s.id===item.id)} onClick={()=>onSetOptions(movement.id,item.id)}/>:item.warmup ? `热身 ${item.number}` : item.number}</td>{movement.tracking !== 'duration' && <td>{movement.load_mode === 'bodyweight' ? '自重' : `${item.weight} ${weightUnitLabel(movement.unit)}`}</td>}<td>{movement.tracking === 'duration' ? item.duration_seconds : item.reps}{acceptsFeedback(movement)&&item.hard_reps!=null&&<small className="st-report-set-feedback">{validHardReps(item)?item.hard_reps?`最后 ${item.hard_reps} 次吃力`:'没有明显吃力':'吃力次数待核对'}</small>}</td></tr>)}</tbody>
          </table>
          {movement.effort && <p className="st-report-effort">体感：{(movement.training_type==='mobility'?{easy:'舒适',normal:'有点紧',hard:'不适'}:{ easy: '简单', normal: '正常', hard: '困难' })[movement.effort]}</p>}
        </div>
      </details>)}
      {report.unrecorded.length > 0 && <details className="st-report-unrecorded">
        <summary className="st-report-disclosure">未记录动作 <span>{report.unrecorded.length} 个</span></summary>
        <ul>{report.unrecorded.map(m => <li key={m.id}>{m.name}</li>)}</ul>
      </details>}
    </section>
    {session.notes.trim() && <section className="st-report-notes"><h3>训练笔记</h3><p>{session.notes}</p></section>}
    <footer className="st-report-actions"><button className="st-secondary" disabled={!session.exercises.length} onClick={onSaveTemplate}>存为模板</button><button className="st-primary" disabled={!canRepeat} onClick={onRepeat}>再次训练 <span aria-hidden="true">↗</span></button></footer>
    <details className="st-report-more"><summary>更多操作</summary>{onEdit&&<button className="st-secondary" onClick={onEdit}>更正本次记录</button>}{onDelete&&<button className="st-report-delete" onClick={onDelete}>删除这场训练</button>}</details>
  </section>
}
