import test from 'node:test'
import assert from 'node:assert/strict'
import {
  newSet, startSession, previousSets, convertWeight, elapsedSeconds,
  summary, togglePause, finishSession, mergeRecords, prefillEmptySession,
  fillFollowingSets, appendExerciseSet,
} from '../src/training/strength.js'

const exercises = [{ id: 'cable-y-raise', name: 'Y字绳索侧平举', equipment: '绳索', load_mode: 'external' }]
const template = { id: 'back', name: '背·三角肌后束·二头', exercises: [{ exercise_id: 'cable-y-raise', set_count: 4, unit: 'lb', rest_seconds: 90 }] }

test('each start has independent sets and does not mutate its template', () => {
  const first = startSession(template, exercises), second = startSession(template, exercises)
  assert.equal(first.exercises[0].sets.length, 4)
  assert.notEqual(first.id, second.id)
  assert.notEqual(first.exercises[0].sets[0].id, second.exercises[0].sets[0].id)
  first.exercises[0].sets[0].weight = 100
  assert.equal(second.exercises[0].sets[0].weight, null)
  assert.equal(template.exercises[0].weight, undefined)
  assert.equal(first.exercises[0].sets[0].reps, null)
})

test('pause and resume survive timer suspension and preserve remaining rest', () => {
  const session = startSession(template, exercises)
  session.started_at = '2026-11-07T12:00:00Z'
  session.rest_until = '2026-11-07T12:03:00Z'
  const paused = togglePause(session, '2026-11-07T12:02:00Z')
  assert.equal(elapsedSeconds(paused, Date.parse('2026-11-07T12:10:00Z')), 120)
  const resumed = togglePause(paused, '2026-11-07T12:07:00Z')
  assert.equal(resumed.paused_seconds, 300)
  assert.equal(resumed.rest_until, '2026-11-07T12:08:00.000Z')
  assert.equal(elapsedSeconds(resumed, Date.parse('2026-11-07T12:10:00Z')), 300)
  const ended = finishSession(paused, 'completed', '2026-11-07T12:07:00Z')
  assert.equal(elapsedSeconds(ended), 120)
  assert.equal(ended.paused_at, null)
  assert.equal(ended.rest_until, null)
})

test('a changed second set fills later unchecked sets without rewriting completed records or warmup flags', () => {
  const movement = startSession(template, exercises).exercises[0]
  movement.sets = [
    newSet({ weight: 50, reps: 8, completed_at: 'recorded', warmup: true }),
    newSet({ weight: 100, reps: 10 }),
    newSet({ weight: 80, reps: 8, completed_at: 'recorded' }),
    newSet({ weight: 80, reps: 8, warmup: true }),
    newSet({ weight: 80, reps: 8 }),
  ]
  const before = structuredClone(movement)
  const filled = fillFollowingSets(movement, movement.sets[1].id)
  assert.deepEqual(movement, before)
  assert.deepEqual(filled.sets.slice(0, 3), before.sets.slice(0, 3))
  assert.deepEqual(filled.sets.slice(3).map(s => [s.weight, s.reps, s.completed_at, s.warmup]), [
    [100, 10, null, true], [100, 10, null, false],
  ])
  assert.equal(summary({ exercises: [filled] }).completed, 2)
})

test('new sets use the latest edited source even when a later planned set has old values', () => {
  const movement = startSession(template, exercises).exercises[0]
  movement.sets = [newSet({ weight: 50, reps: 8 }), newSet({ weight: 105.5, reps: 10, completed_at: 'recorded', warmup: true }), newSet({ weight: 80, reps: 8 })]
  const added = appendExerciseSet(movement, movement.sets[1].id)
  assert.equal(movement.sets.length, 3)
  assert.equal(added.sets.at(-1).weight, 105.5)
  assert.equal(added.sets.at(-1).reps, 10)
  assert.equal(added.sets.at(-1).completed_at, null)
  assert.equal(added.sets.at(-1).warmup, false)
  assert.notEqual(added.sets.at(-1).id, movement.sets[1].id)
  assert.equal(appendExerciseSet(movement, 'removed-row').sets.at(-1).weight, 80)
})

test('batch fill requires source values and preserves bodyweight or assistance semantics', () => {
  const movement = startSession(template, exercises).exercises[0]
  movement.sets = [newSet({ reps: 12 }), newSet({ weight: 80, reps: 8 })]
  assert.equal(fillFollowingSets(movement, movement.sets[0].id), movement)
  assert.equal(fillFollowingSets(movement, 'removed-row'), movement)
  movement.load_mode = 'bodyweight'
  const bodyweight = fillFollowingSets(movement, movement.sets[0].id)
  assert.equal(bodyweight.sets[1].weight, null)
  assert.equal(bodyweight.sets[1].reps, 12)
  assert.equal(appendExerciseSet(bodyweight, bodyweight.sets[0].id).sets.at(-1).weight, null)
  movement.load_mode = 'assistance'
  movement.sets[0].weight = 40
  assert.equal(fillFollowingSets(movement, movement.sets[0].id).sets[1].weight, 40)
})

test('summary counts checked sets and repetitions across load modes, without aggregate load', () => {
  const session = startSession(template, exercises)
  session.exercises[0].sets = [newSet({ weight: 100, reps: 8, completed_at: 'now' }), newSet({ weight: 500, reps: 8 }), newSet({ weight: 30, reps: 8, completed_at: 'now', warmup: true })]
  session.exercises.push({ ...structuredClone(session.exercises[0]), unit: 'kg', sets: [newSet({ weight: 20, reps: 10, completed_at: 'now' })] })
  session.exercises.push({ ...structuredClone(session.exercises[0]), load_mode: 'assistance', sets: [newSet({ weight: 100, reps: 10, completed_at: 'now' })] })
  const stats = summary(session)
  assert.equal(stats.completed, 4)
  assert.equal(stats.totalReps, 36)
  assert.equal(Object.hasOwn(stats, 'volume'), false)
  assert.equal(convertWeight(100, 'lb', 'kg'), 45.36)
})

test('previous completed values prepopulate new sets without completing them', () => {
  const old = startSession(template, exercises)
  old.status = 'completed'
  old.started_at = '2026-11-01T12:00:00Z'
  old.exercises[0].sets[0] = newSet({ weight: 100, reps: 8, completed_at: 'now' })
  assert.equal(previousSets([{ session: old }], 'cable-y-raise')[0].weight, 100)
  assert.deepEqual(previousSets([{ session: old }], 'cable-y-raise', old.id), [])
  const next = startSession(template, exercises, [{ session: old }])
  assert.ok(next.exercises[0].sets.every(s => !s.completed_at && s.weight === 100 && s.reps === 8))
  assert.equal(summary(next).completed, 0)
  assert.equal(summary(next).totalReps, 0)
})

test('prefill converts units, respects load mode, and preserves manual or completed values', () => {
  const old = startSession(template, exercises)
  old.status = 'completed'; old.started_at = '2026-11-01T12:00:00Z'
  old.exercises[0].sets = [newSet({ weight: 100, reps: 8, completed_at: '2026-11-01T12:05:00Z' }), newSet({ weight: 120, reps: 6, completed_at: '2026-11-01T12:07:00Z' })]
  const session = startSession(template, exercises)
  session.exercises[0].unit = 'kg'
  session.exercises[0].sets[0].weight = 50
  session.exercises[0].sets[1] = newSet({ weight: 55, reps: 5, completed_at: 'now' })
  const filled = prefillEmptySession(session, [{ session: old }])
  assert.equal(filled.exercises[0].sets[0].weight, 50)
  assert.equal(filled.exercises[0].sets[0].reps, 8)
  assert.deepEqual(filled.exercises[0].sets[1], session.exercises[0].sets[1])
  assert.equal(filled.exercises[0].sets[2].weight, 54.43)
  assert.equal(filled.exercises[0].sets[2].reps, 6)
  assert.equal(session.exercises[0].sets[0].reps, null)
  const wrongMode = structuredClone(old)
  wrongMode.exercises[0].load_mode = 'assistance'
  assert.deepEqual(previousSets([{ session: wrongMode }], 'cable-y-raise', null, { loadMode: 'external' }), [])
  session.status = 'completed'
  assert.equal(prefillEmptySession(session, [{ session: old }]), session)
})

test('date-only imports from the same local day cannot become a historical comparison', () => {
  const old = startSession(template, exercises)
  old.status = 'completed'; old.started_at = '2026-11-07'
  old.exercises[0].sets = [newSet({ weight: 100, reps: 8, completed_at: 'recorded' })]
  assert.deepEqual(previousSets([{ session: old }], 'cable-y-raise', null, {
    before: '2026-11-08T02:00:00Z', timezone: 'America/New_York', loadMode: 'external',
  }), [])
  const draft = startSession(template, exercises)
  draft.started_at = '2026-11-08T02:00:00Z'; draft.timezone = 'America/New_York'
  const filled = prefillEmptySession(draft, [{ session: old }])
  assert.equal(filled.exercises[0].sets[0].weight, 100)
  assert.equal(filled.exercises[0].sets[0].reps, 8)
  assert.equal(summary(filled).completed, 0)
})

test('server refresh cannot replace an unsynced local edit or downgrade a version', () => {
  const session = startSession(template, exercises)
  const local = { [session.id]: { session, version: 1, dirty: true } }
  const server = { session: { ...session, title: 'older server record' }, version: 2 }
  assert.equal(mergeRecords(local, [server])[session.id].session.title, session.title)
  local[session.id].dirty = false
  local[session.id].alternative = { ...session, title: 'preserved conflict copy' }
  assert.equal(mergeRecords(local, [server])[session.id].session.title, server.session.title)
  assert.equal(mergeRecords(local, [server])[session.id].alternative.title, 'preserved conflict copy')
  local[session.id].version = 3
  assert.equal(mergeRecords(local, [server])[session.id].version, 3)
})

test('server deletions override dirty local records and stale list responses', () => {
  const session = startSession(template, exercises)
  session.status = 'completed'
  const local = { [session.id]: { session, version: 1, dirty: true, alternative: session } }
  const stale = { session, version: 99 }
  const removed = mergeRecords(local, [stale], [session.id])
  assert.equal(removed[session.id], undefined)
  assert.equal(mergeRecords(removed, [stale], new Set([session.id]))[session.id], undefined)
  assert.equal(previousSets(Object.values(removed), 'cable-y-raise').length, 0)
})
