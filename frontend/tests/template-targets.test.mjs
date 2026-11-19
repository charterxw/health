import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { startSession, prefillEmptySession, remainingPlan, changeTemplatePlan, newSet } from '../src/training/strength.js'

const payload = JSON.parse(readFileSync(new URL('./fixtures/template-targets.json', import.meta.url)))
const exercises = JSON.parse(readFileSync(new URL('../../backend/app/data/exercises.json', import.meta.url)))
const templates = payload.requests.slice(0, 8).map(r => r.template)

test('all eight templates start with nine work sets, explicit warmups and exact baseline weights despite older history', () => {
  let total = 0
  for (const t of templates) {
    const old = startSession(t, exercises)
    old.status = 'completed'; old.started_at = '2026-11-01T12:00:00Z'; old.ended_at = '2026-11-01T13:00:00Z'
    old.exercises.forEach(m => m.sets.forEach(s => Object.assign(s, { weight: 999, reps: 99, completed_at: old.ended_at })))
    const next = startSession(t, exercises, [{ session: old }])
    assert.equal(next.exercises.length, 3)
    for (const [i, m] of next.exercises.entries()) {
      const p = t.exercises[i]
      assert.equal(m.rest_seconds, p.rest_seconds)
      assert.equal(m.sets.filter(s => !s.warmup).length, 3)
      assert.equal(m.sets.filter(s => s.warmup).length, p.warmup_count)
      assert.deepEqual(m.sets.map(s => ({ weight: s.weight, reps: s.reps })), p.set_targets)
      assert.ok(m.sets.every(s => s.completed_at === null))
      total += 3
    }
    assert.deepEqual(prefillEmptySession(next, [{ session: old }]), next)
  }
  assert.equal(total, 72)
})

test('post-baseline records remain specific to the same template and preserve mixed loads', () => {
  const t = structuredClone(templates[0])
  t.exercises.forEach(p => { p.targets_updated_at = '2026-11-01T00:00:00Z' })
  const old = startSession(t, exercises)
  old.status = 'completed'; old.started_at = '2026-11-02T12:00:00Z'; old.ended_at = '2026-11-02T13:00:00Z'
  old.exercises.forEach(m => m.sets.forEach(s => { s.completed_at = old.ended_at }))
  old.exercises[0].sets.filter(s => !s.warmup).forEach((s, i) => { s.reps = [8, 7, 6][i] })
  const other = structuredClone(old)
  other.template_id = 'guided-upper-b'; other.started_at = '2026-11-03T12:00:00Z'; other.ended_at = '2026-11-03T13:00:00Z'
  other.exercises.forEach(m => m.sets.forEach(s => { s.weight = 999 }))
  const next = startSession(t, exercises, [{ session: other }, { session: old }])
  assert.deepEqual(next.exercises[0].sets.filter(s => !s.warmup).map(s => s.reps), [8, 7, 6])
  assert.deepEqual(next.exercises[1].sets.filter(s => !s.warmup).map(s => s.weight), [70, 70, 60])
  assert.deepEqual(next.exercises[2].sets.filter(s => !s.warmup).map(s => s.weight), [80, 80, 70])
})

test('remaining plans retain only remaining work targets and editor changes keep targets consistent', () => {
  const p = templates[0].exercises[1]
  const partial = remainingPlan(p, 1)
  assert.equal(partial.warmup_count, 0)
  assert.equal(partial.set_count, 1)
  assert.deepEqual(partial.set_targets, [{ weight: 60, reps: 8 }])
  const changed = changeTemplatePlan(p, 'set_count', 5)
  assert.equal(changed.set_targets.length, 5)
  assert.equal(changed.set_targets.at(-1).weight, 60)
  const kg = changeTemplatePlan(p, 'unit', 'kg')
  assert.equal(kg.set_targets[1].weight, 31.75)
  const reps = changeTemplatePlan(p, 'target_reps', 9)
  assert.equal(reps.set_targets[0].reps, p.set_targets[0].reps)
  assert.ok(reps.set_targets.slice(1).every(s => s.reps === 9))
})

test('refresh does not fill a deliberately cleared baseline field from unrelated history', () => {
  const t = templates[0], session = startSession(t, exercises)
  session.exercises[0].sets[0] = newSet({ warmup: true })
  const wrong = structuredClone(session)
  wrong.status = 'completed'; wrong.started_at = '2026-11-01T12:00:00Z'
  wrong.exercises[0].sets[0] = newSet({ weight: 999, reps: 99, completed_at: '2026-11-01T13:00:00Z', warmup: true })
  assert.deepEqual(prefillEmptySession(session, [{ session: wrong }]), session)
})
