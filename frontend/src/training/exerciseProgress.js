import { convertWeight, localDateKey, setValue } from './strength.js'

export function mergeExerciseHistory(remote, local, deleted = new Set(), complete = true) {
  const records = new Map()
  for (const record of remote) if (!deleted.has(record.session.id)) records.set(record.session.id, record)
  for (const record of local) {
    const id = record.session.id
    if (deleted.has(id) || (complete && /^(imported|archive):/.test(id))) continue
    records.set(id, record)
  }
  return [...records.values()]
}

export function exercisePoints(records, exerciseId, { unit = 'lb', mode = 'external', days = null, now = new Date(), timezone = 'America/New_York' } = {}) {
  const today = localDateKey(now.toISOString(), timezone)
  const cutoff = days == null ? null : localDateKey(new Date(now.getTime() - days * 86400000).toISOString(), timezone)
  return records.flatMap(record => {
    const s = record.session
    const timestamp = Date.parse(s.started_at)
    if (s.status !== 'completed' || !Number.isFinite(timestamp)) return []
    const day = localDateKey(s.started_at, s.timezone || timezone)
    if (day > today || (s.started_at.length > 10 && timestamp > now.getTime()) || (s.ended_at && Date.parse(s.ended_at) > now.getTime()) || (cutoff && day < cutoff)) return []
    const sets = s.exercises.filter(m => m.exercise_id === exerciseId && m.load_mode === mode).flatMap(m =>
      m.sets.filter(row => row.completed_at && !row.warmup && Number(setValue(m, row)) > 0 && Number.isFinite(Number(setValue(m, row)))
        && (mode === 'bodyweight' || (['kg', 'lb'].includes(m.unit) && row.weight != null && Number.isFinite(Number(row.weight)) && Number(row.weight) >= 0)))
        .map(row => ({ ...row, tracking: m.tracking || 'reps', weight: mode === 'bodyweight' ? null : convertWeight(row.weight, m.unit, unit), originalWeight: row.weight, originalUnit: m.unit })))
    if (!sets.length) return []
    const weights = sets.map(row => row.weight)
    const peak = mode === 'bodyweight' ? Math.max(...sets.map(row => Number(setValue(row, row))))
      : mode === 'assistance' ? Math.min(...weights) : Math.max(...weights)
    return [{ id: s.id, date: s.started_at, day, title: s.title, template_id:s.template_id, source: record.source || (/^imported:/.test(s.id) ? 'archive' : 'local'), sets, peak, workSets: sets.length }]
  }).sort((a, b) => a.date.localeCompare(b.date) || a.id.localeCompare(b.id))
}

export function metricPoints(points, metric, weight) {
  return points.flatMap(p => {
    const matching = p.sets.filter(s => Math.abs(s.weight - Number(weight)) < 0.03)
    const value = metric==='total'?(matching.length?matching.reduce((sum,s)=>sum+Number(s.reps),0):null):metric === 'sets' ? p.workSets : metric === 'reps' ? (matching.length ? Math.max(...matching.map(s => Number(s.reps))) : null) : p.peak
    return value == null ? [] : [{ ...p, value, matchingSets:matching.length }]
  })
}
