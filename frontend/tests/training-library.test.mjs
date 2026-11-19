import test from 'node:test'
import assert from 'node:assert/strict'
import { nextPrescription, movementPrescription } from '../src/training/progression.js'
import { startSession, newSet, adoptPrescription, prefillEmptySession } from '../src/training/strength.js'
import { weeklyMuscles, muscleGroups } from '../src/training/muscles.js'
import { buildTrainingReport } from '../src/training/report.js'

const cfg = { exercise_id: 'press', unit: 'lb', load_mode: 'external', work_sets: 3, rep_min: 8, rep_max: 12, increment: 5 }
const when = { before: '2026-11-12T16:00:00Z', timezone: 'America/New_York' }
const row = (reps = 12, weight = 100, values = {}) => newSet({ reps, weight, completed_at: '2026-11-10T16:10:00Z', ...values })
function record(sets = [row(), row(), row()], overrides = {}) {
  return { session: { id: 'old', status: 'completed', started_at: '2026-11-10T16:00:00Z', ended_at: '2026-11-10T16:30:00Z',
    exercises: [{ id: 'movement', exercise_id: 'press', name: '推胸', unit: 'lb', load_mode: 'external', sets, ...overrides }] } }
}

test('all target work sets advance load; actual history and warmups remain unchanged', () => {
  const old = record([row(5, 20, { warmup: true }), row(), row(), row()])
  const copy = structuredClone(old)
  const p = nextPrescription(cfg, [old], when)
  assert.equal(p.weight, 105); assert.equal(p.reps, 8); assert.equal(p.action, 'increase')
  assert.match(p.reason, /全部 3 个工作组/)
  assert.deepEqual(old, copy)
})

test('unchecked rows, fewer sets, changed goals and mixed loads never earn an increase', () => {
  const partial = nextPrescription(cfg, [record([row(), row(), row(12, 100, { completed_at: null })])], when)
  assert.equal(partial.weight, 100); assert.equal(partial.action, 'hold'); assert.match(partial.reason, /2\/3/)
  const fewer = nextPrescription(cfg, [record([row(), row()])], when)
  assert.equal(fewer.action, 'hold'); assert.match(fewer.reason, /组数/)
  const changed = nextPrescription(cfg, [record(undefined, { prescription: { rep_min: 6, rep_max: 10, work_sets: 3 } })], when)
  assert.equal(changed.action, 'hold')
  const mixed = nextPrescription(cfg, [record([row(12, 90), row(), row()])], when)
  assert.equal(mixed.action, 'hold'); assert.equal(mixed.weight, null)
  const below = nextPrescription(cfg, [record([row(), row(11), row(10)])], when)
  assert.equal(below.weight, 100); assert.equal(below.reps, 11); assert.match(below.reason, /还未全部达到/)
})

test('assistance progresses down, bodyweight never gains invented load, unit conversion is explicit', () => {
  const assisted = record([row(12, 4), row(12, 4), row(12, 4)], { load_mode: 'assistance' })
  const p = nextPrescription({ ...cfg, load_mode: 'assistance' }, [assisted], when)
  assert.equal(p.weight, 0); assert.equal(p.action, 'less_assistance')
  const body = nextPrescription({ ...cfg, load_mode: 'bodyweight' }, [record([row(12, null), row(12, null), row(12, null)], { load_mode: 'bodyweight' })], when)
  assert.equal(body.weight, null); assert.equal(body.reps, 12); assert.equal(body.action, 'reps')
  const kg = nextPrescription({ ...cfg, unit: 'kg', increment: 2.5 }, [record()], when)
  assert.equal(kg.weight, 47.86)
  assert.equal(nextPrescription(cfg, [assisted], when).action, 'establish')
})

test('same-day date-only imports, unfinished and future sessions cannot establish progression', () => {
  const sameDay = record(); sameDay.session.started_at = '2026-11-12'; delete sameDay.session.ended_at
  const future = record(); future.session.started_at = '2026-11-13T16:00:00Z'
  const active = record(); active.session.status = 'active'
  assert.equal(nextPrescription(cfg, [sameDay, future, active], when).basis_date, null)
  assert.equal(nextPrescription(cfg, [], when).weight, null)
})

test('enabled templates snapshot prescriptions; manual application preserves checked rows and warmups', () => {
  const exercise = { id: 'press', name: '推胸', equipment: '推胸机', load_mode: 'external', primary_muscles: ['chest'], secondary_muscles: ['triceps'] }
  const template = { id: 't', name: '推', exercises: [{ ...cfg, set_count: 3, progression: 'double' }] }
  const session = startSession(template, [exercise], [record()])
  const movement = session.exercises[0]
  assert.equal(movement.prescription.weight, 105)
  assert.ok(movement.sets.every(s => s.weight === 105 && s.reps === 8 && !s.completed_at))
  assert.deepEqual(movement.primary_muscles, ['chest'])
  template.exercises[0].rep_max = 20
  assert.equal(movement.prescription.rep_max, 12)
  movement.sets[0] = row(5, 20, { warmup: true })
  movement.sets[1] = row(10, 100)
  const applied = adoptPrescription(movement, { ...movement.prescription, weight: 110 })
  assert.deepEqual(applied.sets.slice(0, 2), movement.sets.slice(0, 2))
  assert.equal(applied.sets[2].weight, 110); assert.equal(applied.sets[2].completed_at, null)
})

test('late history fills empty prescription fields without overwriting manual input', () => {
  const exercise = { id: 'press', name: '推胸', equipment: '推胸机', load_mode: 'external' }
  const template = { id: 't', name: '推', exercises: [{ ...cfg, set_count: 3, progression: 'double' }] }
  const session = startSession(template, [exercise])
  session.exercises[0].sets[0].weight = 95
  const filled = prefillEmptySession(session, [record()])
  assert.equal(filled.exercises[0].sets[0].weight, 95)
  assert.equal(filled.exercises[0].sets[1].weight, 105)
  assert.equal(filled.exercises[0].prescription.basis_date, '2026-11-10T16:00:00Z')
  const advice = movementPrescription(record().session.exercises[0], [record()], when)
  assert.equal(advice.weight, 105)
})

test('week uses local Monday and ignores unchecked/warmup/future/discarded work; synergy is separate', () => {
  const catalog = [{ id: 'press', primary_muscles: ['chest'], secondary_muscles: ['triceps'] }]
  const old = record([row(), row(8, 50, { warmup: true }), row(12, 100, { completed_at: null })])
  const sunday = structuredClone(old); sunday.session.id = 'sunday'; sunday.session.started_at = '2026-11-09T04:30:00Z' // Sunday in New York
  const future = structuredClone(old); future.session.id = 'future'; future.session.started_at = '2026-11-13T12:00:00Z'
  const active = structuredClone(old); active.session.id = 'active'; active.session.status = 'active'
  const week = weeklyMuscles([old, old, sunday, future, active], catalog, new Date('2026-11-12T16:00:00Z'), 'America/New_York')
  assert.equal(week.start, '2026-11-09'); assert.equal(week.sets, 1); assert.equal(week.sessions, 1)
  assert.equal(week.groups.find(g => g.id === 'chest').primary, 1)
  assert.equal(week.groups.find(g => g.id === 'triceps').primary, 0)
  assert.equal(week.groups.find(g => g.id === 'triceps').secondary, 1)
  assert.equal(week.unknown, 0)
  const removed = weeklyMuscles([], catalog, new Date('2026-11-12T16:00:00Z'), 'America/New_York')
  assert.equal(removed.sets, 0)
})

test('muscle snapshots win over later catalogue changes and legacy Chinese names still resolve', () => {
  assert.deepEqual(muscleGroups({ primary_muscles: ['chest'], secondary_muscles: ['triceps'] }, { primary_muscles: ['deltoids'] }),
    { primary: ['chest'], secondary: ['triceps'] })
  assert.deepEqual(muscleGroups({ muscles: ['背部'] }).primary, ['upper-back'])
  const old = record([row()], { primary_muscles: ['chest'], secondary_muscles: [] })
  const week = weeklyMuscles([old], [{ id: 'press', primary_muscles: ['deltoids'] }], new Date('2026-11-12T16:00:00Z'), 'America/New_York')
  assert.equal(week.load.chest, 1); assert.equal(week.load.deltoids, 0)
})

test('report suggestions retain planned unchecked work sets instead of shrinking the target', () => {
  const current = record([row(), row(), row(12, 100, { completed_at: null })]).session
  current.timezone = 'America/New_York'; current.paused_seconds = 0
  const report = buildTrainingReport(current, [])
  assert.equal(report.movements[0].sets.length, 2)
  const p = movementPrescription(report.movements[0], [{ session: current }], when)
  assert.equal(p.work_sets, 3); assert.equal(p.action, 'hold')
  assert.match(p.reason, /2\/3/)
})
