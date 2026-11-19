import { hasSetValue, convertWeight, weightUnitLabel, newMovement } from './strength.js'

export function replacementMovement(exercise, original) {
  const pending = original.sets.filter(s => !s.completed_at)
  return newMovement(exercise, {
    set_count: pending.length,
    warmup_count: pending.filter(s => s.warmup).length,
    unit: original.unit,
    rest_seconds: original.rest_seconds,
  })
}

export const isPosture = session => session.exercises.length > 0 && session.exercises.every(m => m.training_type === 'mobility' || m.exercise_id.startsWith('posture-'))
export function workProgress(session) {
  const movements=isPosture(session)?session.exercises:session.exercises.filter(m=>m.training_type!=='mobility'&&!m.exercise_id.startsWith('posture-'))
  const sets = movements.flatMap(m => m.sets.filter(s => !s.warmup).map(s => ({ ...s, valid: hasSetValue(m, s) })))
  const warmups = session.exercises.flatMap(m => m.sets.filter(s => s.warmup))
  return { done: sets.filter(s => s.completed_at && s.valid).length, planned: sets.length,
    warmup: warmups.filter(s => s.completed_at).length, warmupPlanned: warmups.length }
}
export function setLabel(movement, index) {
  const row = movement.sets[index]
  return `${row.warmup ? '热身 ' : ''}${movement.sets.slice(0, index + 1).filter(s => Boolean(s.warmup) === Boolean(row.warmup)).length}`
}
export function finishMessage(session) {
  const p = workProgress(session), unit = isPosture(session) ? '练习组' : '工作组'
  const missing = session.exercises.map(m => ({ name: m.name, count: m.sets.filter(s => !s.warmup && (!s.completed_at || !hasSetValue(m, s))).length })).filter(m => m.count)
  return `已完成 ${p.done}/${p.planned} ${unit}${p.warmup ? `，热身 ${p.warmup} 组` : ''}。${missing.length ? missing.map(m => `${m.name}还剩 ${m.count} 组`).join('；') + '。' : '本次安排已完成。'}`
}
export function toggleSet(session, movementId, setId, now = Date.now()) {
  const doc = structuredClone(session), movement = doc.exercises.find(m => m.id === movementId), row = movement.sets.find(s => s.id === setId)
  if (row.completed_at) {
    row.completed_at = null
    if (doc.rest_set_id === setId) { doc.rest_until = null; doc.rest_set_id = null }
  } else {
    row.completed_at = new Date(now).toISOString()
    const rest = row.warmup ? Math.min(60, movement.rest_seconds) : movement.rest_seconds
    doc.rest_until = rest ? new Date(now + rest * 1000).toISOString() : null
    doc.rest_set_id = rest ? setId : null
  }
  return doc
}
export function sameContext(history, session, movement) {
  const prefix = session.exercises.slice(0, session.exercises.findIndex(m => m.id === movement.id)).map(m => m.exercise_id).join('|')
  return history.filter(({session: old}) => {
    if (session.template_id && old.template_id !== session.template_id) return false
    const i = old.exercises.findIndex(m => m.exercise_id === movement.exercise_id && m.load_mode === movement.load_mode)
    return i >= 0 && old.exercises.slice(0, i).map(m => m.exercise_id).join('|') === prefix
  })
}
export function actualTargets(movement) {
  const rows = movement.sets.filter(s => !s.warmup)
  if (!rows.length) return '按实际完成记录'
  const values = rows.map(s => movement.tracking === 'duration' ? `${s.duration_seconds ?? '—'} 秒`
    : `${movement.load_mode === 'bodyweight' ? '自重' : `${s.weight ?? '—'} ${weightUnitLabel(movement.unit)}`} × ${s.reps ?? '—'}`)
  return values.every(v => v === values[0]) ? `${values[0]} · ${rows.length} 组` : values.join(' ／ ')
}
export function lastPerformance(sets, movement) {
  const rows = sets.filter(s => !s.warmup)
  if (!rows.length) return ''
  const weights = rows.map(s => convertWeight(s.weight, s.unit, movement.unit))
  if (movement.tracking === 'duration') return rows.map(s => s.duration_seconds + '秒').join(' / ')
  if (movement.load_mode === 'bodyweight') return rows.map(s => s.reps).join(' / ') + ' 次'
  return weights.every(w => w === weights[0]) ? `${weights[0]} ${weightUnitLabel(movement.unit)} · ${rows.map(s => s.reps).join(' / ')} 次`
    : rows.map((s, i) => `${weights[i]} × ${s.reps}`).join(' / ') + ` ${weightUnitLabel(movement.unit)}`
}
