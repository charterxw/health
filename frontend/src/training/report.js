import { convertWeight, elapsedSeconds, previousSets, summary } from './strength.js'
import { sameContext } from './ux.js'

function loadGroups(sets, unit) {
  const groups = new Map()
  for (const set of sets) {
    const weight = convertWeight(set.weight, set.unit || unit, unit)
    if (weight == null) continue
    const key = weight.toFixed(2)
    if (!groups.has(key)) groups.set(key, { weight, reps: [] })
    groups.get(key).reps.push(Number(set.reps))
  }
  return groups
}

export function buildTrainingReport(session, history) {
  const stats = summary(session)
  const movements = session.exercises.map(movement => {
    const sets = movement.sets.map((s, i) => ({ ...s, number: movement.sets.slice(0,i+1).filter(r => Boolean(r.warmup) === Boolean(s.warmup)).length })).filter(s => s.completed_at)
    const work = sets.filter(s => !s.warmup)
    const rank = item => movement.tracking === 'duration' ? item.duration_seconds : movement.load_mode === 'bodyweight' ? 0
      : movement.load_mode === 'assistance' ? -Number(item.weight) : Number(item.weight)
    const representative = work.reduce((best, item) =>
      !best || rank(item) > rank(best) || (rank(item) === rank(best) && item.reps > best.reps) ? item : best, null)
    const previous = previousSets(sameContext(history, session, movement), movement.exercise_id, session.id, {
      before: session.started_at, timezone: session.timezone, loadMode: movement.load_mode,
    })
    const oldWork = previous.filter(s => !s.warmup)
    let comparison = null
    if (work.length && oldWork.length && movement.training_type !== 'mobility' && movement.tracking !== 'duration') {
      if (movement.load_mode === 'bodyweight') {
        comparison = { kind: 'bodyweight', currentReps: work.map(s => Number(s.reps)), previousReps: oldWork.map(s => Number(s.reps)) }
      } else {
        const currentGroups = loadGroups(work, movement.unit)
        const oldGroups = loadGroups(oldWork, movement.unit)
        const shared = [...currentGroups.entries()].filter(([key]) => oldGroups.has(key)).sort((a, b) => b[1].weight - a[1].weight)
        if (shared.length) {
          const [key, group] = shared[0]
          comparison = { kind: 'same_load', weight: group.weight, currentReps: group.reps, previousReps: oldGroups.get(key).reps }
        } else {
          comparison = { kind: 'changed_load', currentWeights: [...currentGroups.values()].map(g => g.weight),
            previousWeights: [...oldGroups.values()].map(g => g.weight) }
        }
      }
      if (comparison.currentReps && comparison.currentReps.length === comparison.previousReps.length && work.length===oldWork.length && movement.sets.filter(s=>!s.warmup).length===work.length) {
        comparison.repDelta = comparison.currentReps.reduce((n, value) => n + value, 0)
          - comparison.previousReps.reduce((n, value) => n + value, 0)
      }
      comparison.date = previous[0].date
      comparison.converted = previous.some(s => s.unit !== movement.unit)
    }
    return { ...movement, sets, workSets: work.length, plannedWorkSets: movement.sets.filter(s => !s.warmup).length, representative, previous, comparison,
      totalReps: sets.reduce((n, s) => n + Number(s.reps || 0), 0) }
  })
  const completed = movements.filter(m => m.sets.length)
  const allSets = completed.flatMap(m => m.sets)
  const highlight = completed.reduce((best, movement) =>
    (movement.comparison?.repDelta ?? 0) > (best?.comparison.repDelta ?? 0) ? movement : best, null)
  return { ...stats, duration: elapsedSeconds(session), movements: completed,
    highlight,
    unrecorded: movements.filter(m => !m.sets.length),
    totalReps: allSets.reduce((n, s) => n + Number(s.reps || 0), 0),
    warmupSets: allSets.filter(s => s.warmup).length,
    workSets: allSets.filter(s => !s.warmup).length,
    externalSets: completed.filter(m => m.load_mode === 'external').reduce((n, m) => n + m.workSets, 0),
    assistanceSets: completed.filter(m => m.load_mode === 'assistance').reduce((n, m) => n + m.workSets, 0),
    bodyweightSets: completed.filter(m => m.load_mode === 'bodyweight').reduce((n, m) => n + m.workSets, 0),
  }
}
