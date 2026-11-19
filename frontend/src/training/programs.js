export function templateCounts(template) {
  const total = template.exercises.reduce((n, m) => n + m.set_count, 0)
  const warmup = template.exercises.reduce((n, m) => n + (m.warmup_count || 0), 0)
  return { total, warmup, work: total - warmup }
}

export function nextRoutine(templates, history) {
  const cycle = templates.filter(r => Number.isInteger(r.template.rotation_order))
    .sort((a, b) => a.template.rotation_order - b.template.rotation_order)
  if (!cycle.length) return null
  const ids = cycle.map(r => r.template.id)
  const completed = history.filter(r => r.session.status === 'completed' && ids.includes(r.session.template_id)
    && Date.parse(r.session.started_at) <= Date.now() && (!r.session.ended_at || Date.parse(r.session.ended_at) <= Date.now())
    && r.session.exercises.some(m => m.sets.some(s => s.completed_at && !s.warmup && Number(s.reps) > 0)))
    .sort((a, b) => b.session.started_at.localeCompare(a.session.started_at))
  const last = completed[0]?.session
  return { record: cycle[last ? (ids.indexOf(last.template_id) + 1) % cycle.length : 0], cycle, last }
}

export function sessionTemplate(session) {
  return { id: session.template_id, name: session.title, notes: session.template_notes || '',
    duration_min: session.duration_min ?? null, duration_max: session.duration_max ?? null,
    exercises: session.exercises.map(m => {
      const count = Math.min(m.sets.length, 30)
      const sets = m.sets.slice(0, count)
      const warmup = sets.filter(s => s.warmup).length
      const contiguous = sets.every((s, i) => Boolean(s.warmup) === (i < warmup))
      return { exercise_id: m.exercise_id, set_count: count, unit: m.unit, rest_seconds: m.rest_seconds,
        ...(m.tracking === 'duration' ? { target_seconds: sets[0]?.duration_seconds ?? null } : {}),
        ...(contiguous && warmup < count ? { warmup_count: warmup } : {}),
        ...(m.prescription ? { progression: 'double', rep_min: m.prescription.rep_min, rep_max: m.prescription.rep_max, increment: m.prescription.increment } : {}) }
    }) }
}
