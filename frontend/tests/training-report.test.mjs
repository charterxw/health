import test from 'node:test'
import assert from 'node:assert/strict'
import { startSession, newSet } from '../src/training/strength.js'
import { buildTrainingReport } from '../src/training/report.js'

const exercise = { id: 'pulldown', name: '下拉', equipment: '绳索', load_mode: 'external' }
const template = { id: 'back', name: '背部', exercises: [{ exercise_id: 'pulldown', set_count: 3, unit: 'lb' }] }
function session(date, sets, mode = 'external') {
  const value = startSession(template, [exercise])
  value.status = 'completed'; value.started_at = `${date}T12:00:00Z`; value.ended_at = `${date}T12:20:00Z`
  value.exercises[0].load_mode = mode
  value.exercises[0].sets = sets
  return value
}
const done = (weight, reps, warmup = false) => newSet({ weight, reps, warmup, completed_at: 'recorded' })

test('report excludes prefilled unchecked rows and keeps warmups separate', () => {
  const current = session('2026-11-08', [done(50, 8, true), done(100, 9), newSet({ weight: 200, reps: 20 })])
  const report = buildTrainingReport(current, [])
  assert.equal(report.completed, 2)
  assert.equal(report.totalReps, 17)
  assert.equal(report.warmupSets, 1)
  assert.equal(report.workSets, 1)
  assert.equal(Object.hasOwn(report, 'volume'), false)
  assert.equal(Object.hasOwn(report.movements[0], 'volume'), false)
  assert.equal(report.duration, 1200)
  assert.equal(report.movements[0].sets.length, 2)
  assert.equal(report.movements[0].representative.weight, 100)
  assert.equal(report.highlight, null)
})

test('comparison uses only earlier matching workouts, not a newer workout or a different load mode', () => {
  const old = session('2026-11-01', [done(100, 8), done(100, 8)])
  const future = session('2026-11-09', [done(100, 30)])
  const assisted = session('2026-11-07', [done(100, 15)], 'assistance')
  const current = session('2026-11-08', [done(100, 9), done(100, 8)])
  const report = buildTrainingReport(current, [{ session: future }, { session: current }, { session: assisted }, { session: old }])
  const comparison = report.movements[0].comparison
  assert.equal(comparison.date, old.started_at)
  assert.equal(comparison.weight, 100)
  assert.equal(comparison.repDelta, 1)
  assert.equal(report.highlight, report.movements[0])
})

test('different set counts are shown as records without a same-set performance delta', () => {
  const old = session('2026-11-01', [done(100, 8)])
  const current = session('2026-11-08', [done(100, 8), done(100, 8)])
  const report = buildTrainingReport(current, [{ session: old }])
  const comparison = report.movements[0].comparison
  assert.equal(comparison.repDelta, undefined)
  assert.equal(comparison.currentReps.length, 2)
  assert.equal(report.highlight, null)
})

test('assistance and bodyweight keep their own set types and per-set records', () => {
  const old = session('2026-11-01', [done(60, 8)], 'assistance')
  const current = session('2026-11-08', [done(40, 10)], 'assistance')
  const bodyweight = structuredClone(current.exercises[0])
  bodyweight.id = crypto.randomUUID(); bodyweight.exercise_id = 'squat'; bodyweight.load_mode = 'bodyweight'
  bodyweight.sets = [done(null, 12)]
  current.exercises.push(bodyweight)
  const report = buildTrainingReport(current, [{ session: old }])
  assert.equal(Object.hasOwn(report, 'volume'), false)
  assert.equal(report.totalReps, 22)
  assert.equal(report.movements[0].sets[0].weight, 40)
  assert.equal(report.assistanceSets, 1)
  assert.equal(report.bodyweightSets, 1)
  assert.equal(report.movements[0].comparison.kind, 'changed_load')
})

test('an empty completed workout has no inferred performance', () => {
  const current = session('2026-11-08', [newSet({ weight: 100, reps: 8 })])
  const report = buildTrainingReport(current, [])
  assert.equal(report.completed, 0)
  assert.equal(report.totalReps, 0)
  assert.equal(report.movements.length, 0)
  assert.equal(report.unrecorded.length, 1)
})
