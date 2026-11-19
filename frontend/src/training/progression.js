// Double progression, informed by openGym's history-derived prescriptions.
// Actual sets remain facts; a recommendation never marks a set as performed.
const round = n => Math.round(n * 100) / 100
const convert = (n, from, to) => n == null ? null : round(from === to ? Number(n) : from === 'lb' ? n * 0.45359237 : n / 0.45359237)
const complete = (s, mode) => Boolean(s.completed_at) && Number(s.reps) > 0 &&
  (mode === 'bodyweight' || (s.weight != null && Number.isFinite(Number(s.weight)) && Number(s.weight) >= 0))

export function progressionRule(plan = {}) {
  const min = Number(plan.rep_min ?? 8), max = Number(plan.rep_max ?? 12)
  const increment = Number(plan.increment ?? (plan.unit === 'kg' ? 2.5 : 5))
  return { rep_min: min, rep_max: max, increment }
}

function calendarDay(value, timezone) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(value))
}

export function nextPrescription(config, history, { before = new Date().toISOString(), timezone = 'America/New_York', currentId } = {}) {
  if (config.tracking === 'duration' || config.training_type === 'mobility') return null
  const { rep_min: min, rep_max: max, increment } = progressionRule(config)
  const count = Number(config.work_sets ?? config.set_count ?? 3)
  const mode = config.load_mode || 'external', unit = config.unit || 'lb'
  if (!(min >= 1 && min <= max && max <= 100 && increment > 0 && increment <= 100 && count >= 1 && count <= 50)) return null
  const result = { policy: 'double', rep_min: min, rep_max: max, increment, work_sets: count,
    weight: null, reps: min, action: 'establish', reason: '还没有可比的工作组。先选择能稳定完成目标次数的重量。', basis_date: null }
  const ordered = [...history].sort((a, b) => b.session.started_at.localeCompare(a.session.started_at))
  for (const { session } of ordered) {
    if (session.id === currentId || session.status !== 'completed') continue
    if (session.ended_at && Date.parse(session.ended_at) > Date.parse(before)) continue
    const date = session.started_at
    if (date.length === 10 ? date >= calendarDay(before, timezone) : !Number.isFinite(Date.parse(date)) || Date.parse(date) >= Date.parse(before)) continue
    const movements = session.exercises.filter(m => m.exercise_id === config.exercise_id && m.load_mode === mode)
    if (!movements.length) continue
    const work = movements.flatMap(m => m.sets.filter(s => !s.warmup).map(s => ({ ...s, unit: m.unit })))
    const done = work.filter(s => complete(s, mode))
    if (!done.length) continue
    result.basis_date = date
    result.action = 'hold'
    const weights = done.map(s => convert(s.weight, s.unit, unit))
    const uniform = mode === 'bodyweight' || weights.every(w => w != null && Math.abs(w - weights[0]) < 0.02)
    result.weight = mode === 'bodyweight' || !uniform ? null : weights[0]
    result.reps = Math.min(max, Math.max(min, Math.min(...done.map(s => Number(s.reps))) + 1))
    if (movements.length !== 1 || !uniform) {
      result.reason = '上次包含不同重量或同动作的多段记录。先沿用各组重量，不自动加重。'
      return result
    }
    const prior = movements[0].prescription
    if (work.length !== count || (prior && (prior.rep_min !== min || prior.rep_max !== max || prior.work_sets !== count))) {
      result.reason = '组数或次数目标与上次不同。先在新目标下完成一场训练，再判断是否加重。'
      return result
    }
    if (done.length !== work.length) {
      result.reps = min
      result.reason = `上次完成 ${done.length}/${work.length} 个工作组，尚未全部完成。保持重量，先完成目标组。`
      return result
    }
    if (!done.every(s => Number(s.reps) >= max)) {
      result.reason = `上次 ${done.map(s => s.reps).join(' / ')} 次，还未全部达到 ${max} 次。保持重量，在 ${min}–${max} 次内推进。`
      return result
    }
    if (mode === 'bodyweight') {
      result.action = 'reps'; result.reps = max
      result.reason = `全部 ${count} 个工作组达到 ${max} 次。可维持次数，或调整目标区间；不会自动添加负重。`
      return result
    }
    const target = round(mode === 'assistance' ? Math.max(0, result.weight - increment) : result.weight + increment)
    if (target === result.weight || target > 2000) {
      result.action = 'limit'; result.reps = max
      result.reason = '已达到当前记重范围的边界。保持本次重量，手动调整后续目标。'
      return result
    }
    const previousWeight = result.weight
    result.action = mode === 'assistance' ? 'less_assistance' : 'increase'
    result.weight = target; result.reps = min
    result.reason = `全部 ${count} 个工作组达到 ${max} 次，建议${mode === 'assistance' ? '减少辅助量' : '增加重量'}：${previousWeight} → ${target} ${unit === 'kg' ? '公斤' : '磅'}，次数回到 ${min} 次。`
    return result
  }
  return result
}

export function movementPrescription(movement, history, options = {}) {
  const count = movement.plannedWorkSets ?? movement.sets.filter(s => !s.warmup).length
  if (!count) return null
  return nextPrescription({ ...movement, ...movement.prescription, work_sets: count }, history, options)
}

export function prescriptionLabel(value, mode, unit) {
  if (!value) return ''
  const weight = mode === 'bodyweight' ? '自重' : value.weight == null ? '各组原重量'
    : `${mode === 'assistance' ? '辅助 ' : ''}${value.weight} ${unit === 'kg' ? '公斤' : '磅'}`
  return `${weight} · ${value.work_sets} 组 × ${value.reps} 次`
}
