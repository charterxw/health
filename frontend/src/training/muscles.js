import { localDateKey, setValue } from './strength.js'

export const MUSCLE_NAMES = {
  trapezius: '斜方肌', deltoids: '肩部', chest: '胸部', 'upper-back': '背部', serratus: '前锯肌',
  biceps: '肱二头肌', triceps: '肱三头肌', forearm: '前臂', abs: '腹部', obliques: '腹斜肌',
  'lower-back': '下背部', gluteal: '臀部', quadriceps: '股四头肌', hamstring: '腘绳肌',
  adductors: '内收肌', 'hip-flexors': '髋屈肌', calves: '小腿', tibialis: '胫骨前肌',
}
export const MUSCLE_IDS = Object.keys(MUSCLE_NAMES)
export const INERT_PARTS = ['head', 'hair', 'neck', 'hands', 'feet', 'knees', 'ankles']
const aliases = { ...Object.fromEntries(Object.entries(MUSCLE_NAMES).map(([id, name]) => [name, id])),
  肩后束: 'deltoids', 肩中束: 'deltoids', 手臂: 'forearm', 背阔肌: 'upper-back', 胸肌: 'chest' }
const canonical = list => [...new Set((list || []).map(id => aliases[id] || id).filter(id => MUSCLE_NAMES[id]))]

export function muscleGroups(movement = {}, catalogEntry = {}) {
  const primary = canonical(movement.primary_muscles?.length ? movement.primary_muscles
    : catalogEntry.primary_muscles?.length ? catalogEntry.primary_muscles : movement.muscles ?? catalogEntry.muscles)
  const secondary = canonical(movement.secondary_muscles ?? catalogEntry.secondary_muscles).filter(id => !primary.includes(id))
  return { primary, secondary }
}

export function templateMuscles(template, catalog) {
  const index = new Map(catalog.map(e => [e.id, e]))
  const load = {}
  for (const plan of template.exercises) {
    const { primary } = muscleGroups(index.get(plan.exercise_id))
    for (const id of primary) load[id] = (load[id] || 0) + Math.max(0, Number(plan.set_count || 0) - (plan.warmup_count || 0))
  }
  return load
}

function shiftDay(day, amount) {
  const date = new Date(`${day}T12:00:00Z`)
  date.setUTCDate(date.getUTCDate() + amount)
  return date.toISOString().slice(0, 10)
}

export function weeklyMuscles(history, catalog, now = new Date(), timezone = Intl.DateTimeFormat().resolvedOptions().timeZone) {
  const today = localDateKey(now.toISOString(), timezone)
  const weekday = new Date(`${today}T12:00:00Z`).getUTCDay()
  const start = shiftDay(today, -((weekday + 6) % 7))
  const index = new Map(catalog.map(e => [e.id, e])), seen = new Set()
  const groups = Object.fromEntries(MUSCLE_IDS.map(id => [id, { id, name: MUSCLE_NAMES[id], primary: 0, secondary: 0, last: null }]))
  let sets = 0, sessions = 0, unknown = 0
  for (const { session } of history) {
    if (session.status !== 'completed' || seen.has(session.id)) continue
    const day = localDateKey(session.started_at, timezone)
    if (day < start || day > today || (session.started_at.length > 10 && Date.parse(session.started_at) > +now)) continue
    seen.add(session.id)
    let performed = 0
    for (const movement of session.exercises) {
      if ((movement.training_type || index.get(movement.exercise_id)?.training_type) === 'mobility') continue
      const work = movement.sets.filter(s => s.completed_at && !s.warmup && Number(setValue(movement, s)) > 0).length
      if (!work) continue
      sets += work; performed += work
      const { primary, secondary } = muscleGroups(movement, index.get(movement.exercise_id))
      if (!primary.length) unknown += work
      for (const id of primary) { groups[id].primary += work; groups[id].last = !groups[id].last || day > groups[id].last ? day : groups[id].last }
      for (const id of secondary) groups[id].secondary += work
    }
    if (performed) sessions++
  }
  return { start, end: today, sets, sessions, unknown, groups: Object.values(groups),
    load: Object.fromEntries(Object.entries(groups).map(([id, value]) => [id, value.primary])) }
}
