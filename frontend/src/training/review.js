import { buildTrainingReport } from './report.js'
import { nextPrescription } from './progression.js'
import {sameContext,workProgress} from './ux.js'
import { hasSetValue } from './strength.js'

export function sessionReview(session, history) {
  const report = buildTrainingReport(session, history)
  const progress=workProgress(session)
  const planned = progress.planned
  const items = session.exercises.map(m => {
    const work = m.sets.filter(s => !s.warmup)
    const done = work.filter(s => s.completed_at && hasSetValue(m, s))
    if (!done.length) return { id: m.id, name: m.name, count: 0, planned: work.length, target: null, drop: null, next: null }
    const target = m.prescription ? { min: m.prescription.rep_min, max: m.prescription.rep_max,
      met: done.filter(s => Number(s.reps) >= m.prescription.rep_min).length,
      top: done.filter(s => Number(s.reps) >= m.prescription.rep_max).length } : null
    const uniform = m.load_mode === 'bodyweight' || done.every(s => Number(s.weight) === Number(done[0].weight))
    const drop = uniform && done.length >= 2 && Number(done.at(-1).reps) < Number(done[0].reps)
      ? { first: done[0].reps, last: done.at(-1).reps, weight: done[0].weight } : null
    const next = m.prescription ? nextPrescription({ ...m, ...m.prescription, work_sets: work.length },
      [...sameContext(history,session,m).filter(r => r.session.id !== session.id), { session }],
      { before: new Date(Date.parse(session.ended_at) + 1).toISOString(), timezone: session.timezone }) : null
    return { id: m.id, name: m.name, count: done.length, planned: work.length, target, drop, next }
  })
  return { planned, completed: progress.done, warmup: report.warmupSets,
    duration: Math.round(report.duration / 60), budget: session.duration_min != null ? [session.duration_min, session.duration_max] : null, items }
}
