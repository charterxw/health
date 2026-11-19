import { nextPrescription } from './progression.js'

export const STORE_KEY = 'health-strength-records-v1'
export const CATALOG_KEY = 'health-strength-catalog-v1'
export const DELETIONS_KEY = 'health-strength-deletions-v1'
export const weightUnitLabel = unit => unit === 'kg' ? '公斤' : ['lb', 'lbs'].includes(unit) ? '磅' : unit
export const uid = () => {
  if (crypto.randomUUID) return crypto.randomUUID()
  // LAN HTTP can expose getRandomValues without exposing randomUUID.
  const bytes = crypto.getRandomValues(new Uint8Array(16))
  bytes[6] = (bytes[6] & 15) | 64
  bytes[8] = (bytes[8] & 63) | 128
  const hex = [...bytes].map(v => v.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}
export const clone = (value) => JSON.parse(JSON.stringify(value))
export const isTimed = movement => movement.tracking === 'duration'
export const setValue = (movement, item) => item?.[isTimed(movement) ? 'duration_seconds' : 'reps']
export const hasSetValue = (movement, item) => Number(setValue(movement, item)) > 0 && (movement.load_mode === 'bodyweight' || item?.weight != null)

export function targetHistory(history, templateId, baselineAt) {
  if (!baselineAt) return history
  return history.filter(({ session }) => session.template_id === templateId &&
    session.started_at?.length > 10 && Date.parse(session.started_at) >= Date.parse(baselineAt))
}

export function changeTemplatePlan(plan, key, value) {
  const next = { ...plan, [key]: value }
  if (key === 'unit' && plan.increment != null) next.increment = Math.max(0.01, convertWeight(plan.increment, plan.unit, value))
  if (!plan.set_targets) return next
  if (key === 'warmup_count' && value == null) {
    next.set_targets = null; next.targets_updated_at = null
    return next
  }
  let targets = plan.set_targets.map(t => ({ ...t }))
  if (key === 'unit') targets = targets.map(t => ({ ...t, weight: convertWeight(t.weight, plan.unit, value) }))
  if (key === 'target_reps' && value != null) targets = targets.map((t, i) => i >= (plan.warmup_count || 0) ? { ...t, reps: value } : t)
  if (key === 'set_count' || key === 'warmup_count') {
    const warm = targets.slice(0, plan.warmup_count || 0), work = targets.slice(plan.warmup_count || 0)
    const count = Math.max(1, Number(next.set_count) || 1), warmCount = Math.min(count - 1, Number(next.warmup_count) || 0)
    targets = Array.from({ length: count }, (_, i) => ({ ...(i < warmCount
      ? warm[i] || warm.at(-1) || { weight: null, reps: 8 }
      : work[i - warmCount] || work.at(-1) || { weight: null, reps: next.target_reps || 8 }) }))
  }
  next.set_targets = targets
  if (['unit', 'target_reps', 'set_count', 'warmup_count'].includes(key)) next.targets_updated_at = new Date().toISOString()
  return next
}

export function remainingPlan(plan, count) {
  const next = { ...plan, set_count: count, warmup_count: 0 }
  if (plan.set_targets) {
    next.set_targets = plan.set_targets.slice(plan.warmup_count || 0).slice(-count)
    next.prefer_targets = true
  }
  return next
}

export function targetLabel(plan) {
  const work = plan.set_targets?.slice(plan.warmup_count || 0)
  if (!work?.length) return ''
  const same = work.every(t => t.weight === work[0].weight && t.reps === work[0].reps)
  const weight = t => t.weight == null ? '自定重量' : `${t.weight} ${plan.unit || 'lb'}`
  if (same) return `${weight(work[0])} × ${work[0].reps} 次 · ${work.length} 组`
  if (work.every(t => t.weight != null && t.reps === work[0].reps)) return `${work.map(t => t.weight).join(' / ')} ${plan.unit || 'lb'} · 各 ${work[0].reps} 次`
  return work.map(t => `${weight(t)} × ${t.reps}`).join(' / ')
}

export function newSet(values = {}) {
  return { id: uid(), weight: null, reps: null, duration_seconds: null, completed_at: null, warmup: false, hard_reps: null, ...values }
}

export function fillFollowingSets(movement, sourceId) {
  const index = movement.sets.findIndex(item => item.id === sourceId)
  const source = movement.sets[index]
  if (!source || !hasSetValue(movement, source)) return movement
  return { ...movement, sets: movement.sets.map((item, i) => i > index && !item.completed_at
    ? { ...item, weight: movement.load_mode === 'bodyweight' ? null : source.weight, reps: source.reps, ...(isTimed(movement) ? { duration_seconds: source.duration_seconds } : {}) }
    : item) }
}

export function appendExerciseSet(movement, sourceId) {
  if (movement.sets.length >= 50) return movement
  const source = movement.sets.find(item => item.id === sourceId) || movement.sets.at(-1)
  return { ...movement, sets: [...movement.sets, newSet({
    weight: movement.load_mode === 'bodyweight' ? null : source?.weight ?? null,
    reps: source?.reps ?? null,
    duration_seconds: isTimed(movement) ? source?.duration_seconds ?? null : null,
  })] }
}

export function newMovement(exercise, plan = {}, previous = []) {
  const unit = plan.unit || previous[0]?.unit || 'lb'
  return {
    id: uid(), exercise_id: exercise.id, name: exercise.name, equipment: exercise.equipment, weight_note: exercise.weight_note || '',
    load_mode: exercise.load_mode, unit,
    tracking: exercise.tracking || 'reps', training_type: exercise.training_type || 'strength',
    rest_seconds: plan.rest_seconds ?? 90, effort: null,
    primary_muscles: exercise.primary_muscles ? [...exercise.primary_muscles] : null,
    secondary_muscles: exercise.secondary_muscles ? [...exercise.secondary_muscles] : null,
    prescription: null,
    ...(plan.set_targets ? { baseline_at: plan.targets_updated_at } : {}),
    sets: Array.from({ length: plan.set_count || 3 }, (_, index) => {
      const warmup = plan.warmup_count != null ? index < plan.warmup_count : Boolean(previous[index]?.warmup)
      const compatible = plan.warmup_count != null ? previous.filter(s => Boolean(s.warmup) === warmup) : previous
      const hintIndex = plan.warmup_count != null && !warmup ? index - plan.warmup_count : index
      const preset = plan.set_targets?.[index]
      const hint = plan.prefer_targets ? null : compatible[hintIndex] || (!preset ? compatible.at(-1) : null)
      const weight = exercise.load_mode === 'bodyweight' ? null : hint?.weight != null ? convertWeight(hint.weight, hint.unit, unit) : preset?.weight ?? null
      return newSet({ weight: weight != null && weight <= 2000 ? weight : null,
        reps: isTimed(exercise) ? null : hint?.reps ?? preset?.reps ?? plan.target_reps ?? null,
        duration_seconds: isTimed(exercise) ? hint?.duration_seconds ?? plan.target_seconds ?? null : null,
        warmup })
    }),
  }
}

export function adoptPrescription(movement, prescription, onlyEmpty = false) {
  if (!prescription) return movement
  const canFill = prescription.weight != null || movement.load_mode === 'bodyweight'
  return { ...movement, prescription: { ...prescription }, sets: movement.sets.map(s => {
    if (s.completed_at || s.warmup) return s
    return { ...s,
      weight: canFill && (!onlyEmpty || s.weight == null) ? prescription.weight : s.weight,
      reps: (canFill || prescription.action === 'establish') && (!onlyEmpty || s.reps == null) ? prescription.reps : s.reps,
    }
  }) }
}

export function startSession(template, exercises, history = []) {
  const startedAt = new Date().toISOString()
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/New_York'
  return {
    id: uid(), template_id: template?.id || null, title: template?.name || '自由力量训练',
    started_at: startedAt, ended_at: null, timezone,
    status: 'active', paused_at: null, paused_seconds: 0, rest_until: null, notes: '',
    template_notes: template?.notes || '', duration_min: template?.duration_min ?? null, duration_max: template?.duration_max ?? null,
    exercises: (template?.exercises || []).map(plan => {
      const exercise = exercises.find(e => e.id === plan.exercise_id)
      const scoped = targetHistory(history, template.id, plan.set_targets ? plan.targets_updated_at : null)
      const previous = previousSets(scoped, plan.exercise_id, null,
        { before: startedAt, timezone, loadMode: exercise?.load_mode, allowSameDay: true })
      const movement = newMovement(exercise, plan, previous)
      if (plan.progression !== 'double' || plan.prefer_targets || (plan.set_targets && !previous.some(s => !s.warmup))) return movement
      const workSets = movement.sets.filter(s => !s.warmup).length
      return adoptPrescription(movement, nextPrescription({ ...plan, unit: movement.unit, load_mode: movement.load_mode, work_sets: workSets }, scoped,
        { before: startedAt, timezone }))
    }),
  }
}

export function localDateKey(value, timezone) {
  if (value.length === 10) return value
  const parts = new Intl.DateTimeFormat('en', { timeZone: timezone,
    year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date(value))
  const part = name => parts.find(p => p.type === name).value
  return `${part('year')}-${part('month')}-${part('day')}`
}

export function previousSets(history, exerciseId, currentId, { before, timezone, loadMode, allowSameDay = false } = {}) {
  const ordered = [...history].sort((a, b) => b.session.started_at.localeCompare(a.session.started_at))
  for (const record of ordered) {
    const session = record.session
    if (session.id === currentId || session.status !== 'completed') continue
    if (before && session.ended_at && new Date(session.ended_at) > new Date(before)) continue
    // Same-day date-only imports can supply draft values, but cannot establish
    // ordering for a report comparison.
    if (before && (session.started_at.length === 10
      ? (allowSameDay ? session.started_at > localDateKey(before, timezone) : session.started_at >= localDateKey(before, timezone))
      : new Date(session.started_at) >= new Date(before))) continue
    const sets = session.exercises.filter(m => m.exercise_id === exerciseId && (!loadMode || m.load_mode === loadMode)).flatMap(m =>
      m.sets.filter(s => s.completed_at && hasSetValue(m, s)
        && (m.load_mode === 'bodyweight' || (s.weight != null && Number.isFinite(Number(s.weight)) && Number(s.weight) >= 0)))
        .map(s => ({ ...s, unit: m.unit, date: session.started_at, load_mode: m.load_mode })),
    )
    if (sets.length) return sets
  }
  return []
}

export function prefillEmptySession(session, history) {
  if (session.status !== 'active') return session
  const next = clone(session)
  let changed = false
  for (let mi = 0; mi < next.exercises.length; mi++) {
    let movement = next.exercises[mi]
    const scoped = targetHistory(history, session.template_id, movement.baseline_at)
    if (movement.prescription && !movement.prescription.basis_date) {
      const advice = nextPrescription({ ...movement, ...movement.prescription }, scoped,
        { before: session.started_at, timezone: session.timezone, currentId: session.id })
      if (advice?.basis_date) {
        movement = adoptPrescription(movement, advice, true)
        next.exercises[mi] = movement
        changed = true
      }
    }
    const previous = previousSets(scoped, movement.exercise_id, session.id, {
      before: session.started_at, timezone: session.timezone, loadMode: movement.load_mode, allowSameDay: true,
    })
    movement.sets.forEach((item, index) => {
      if (item.completed_at) return
      const compatible = previous.filter(s => Boolean(s.warmup) === Boolean(item.warmup))
      const position = movement.sets.slice(0, index).filter(s => Boolean(s.warmup) === Boolean(item.warmup)).length
      const hint = compatible[position] || compatible.at(-1)
      if (!hint) return
      if (isTimed(movement)) {
        if (item.duration_seconds == null && hint.duration_seconds != null) { item.duration_seconds = hint.duration_seconds; changed = true }
        return
      }
      const target = !item.warmup ? movement.prescription : null
      const weight = target?.weight ?? convertWeight(hint.weight, hint.unit, movement.unit)
      if (item.weight == null && movement.load_mode !== 'bodyweight' && weight != null && weight <= 2000) {
        item.weight = weight; changed = true
      }
      if (item.reps == null && hint.reps != null) { item.reps = target?.reps ?? hint.reps; changed = true }
    })
  }
  return changed ? next : session
}

export function convertWeight(value, from, to) {
  if (value == null) return null
  return Math.round((from === to ? value : from === 'lb' ? value * 0.45359237 : value / 0.45359237) * 100) / 100
}

export function elapsedSeconds(session, now = Date.now()) {
  const end = new Date(session.ended_at || session.paused_at || now).getTime()
  return Math.max(0, Math.floor((end - new Date(session.started_at).getTime()) / 1000 - session.paused_seconds))
}

export function clockText(seconds) {
  const value = Math.max(0, Math.floor(seconds))
  const minutes = Math.floor(value / 60)
  return `${String(minutes).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`
}

export function summary(session) {
  const completed = session.exercises.flatMap(m => m.sets.filter(s => s.completed_at).map(s => ({ ...s, movement: m })))
  return {
    completed: completed.length,
    planned: session.exercises.reduce((n, m) => n + m.sets.length, 0),
    movements: session.exercises.filter(m => m.sets.some(s => s.completed_at)).length,
    totalReps: completed.reduce((n, s) => n + Number(s.reps || 0), 0),
    totalSeconds: completed.reduce((n, s) => n + Number(s.duration_seconds || 0), 0),
  }
}

export function togglePause(session, now = new Date().toISOString()) {
  const next = clone(session)
  if (next.paused_at) {
    const gap = Math.max(0, (new Date(now) - new Date(next.paused_at)) / 1000)
    next.paused_seconds += gap
    if (next.rest_until) next.rest_until = new Date(new Date(next.rest_until).getTime() + gap * 1000).toISOString()
    next.paused_at = null
  } else next.paused_at = now
  return next
}

export function finishSession(session, status = 'completed', now = new Date().toISOString()) {
  const next = session.paused_at ? togglePause(session, now) : clone(session)
  return { ...next, status, ended_at: now, rest_until: null }
}

export function mergeRecords(local, remote, deletedIds = []) {
  const deleted = new Set(deletedIds)
  const records = { ...local }
  for (const record of remote) {
    const old = records[record.session.id]
    if (!old || (!old.dirty && record.version >= old.version)) {
      records[record.session.id] = { ...old, ...record, dirty: false }
    }
  }
  for (const id of deleted) delete records[id]
  return records
}
