import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { startSession, newSet, prefillEmptySession } from '../src/training/strength.js'
import { nextRoutine, sessionTemplate, templateCounts } from '../src/training/programs.js'
import { exercisePoints, mergeExerciseHistory, metricPoints } from '../src/training/exerciseProgress.js'
import { sessionReview } from '../src/training/review.js'
const templates = JSON.parse(readFileSync(new URL('../../backend/app/data/programs.json', import.meta.url)))
const exercises = JSON.parse(readFileSync(new URL('../../backend/app/data/exercises.json', import.meta.url)))
const row = (weight, reps, extra = {}) => newSet({ weight, reps, completed_at: '2026-11-01T13:00:00Z', ...extra })
function record(id, date, sets, mode = 'external', unit = 'lb') {
  return { session: { id, title: id, status: 'completed', started_at: `${date}T12:00:00Z`, ended_at: `${date}T13:00:00Z`, timezone: 'America/New_York', paused_seconds: 0, exercises: [{ id: 'm', exercise_id: 'barbell-bench-press', name: '卧推', load_mode: mode, unit, sets }] } }
}
const now = new Date('2026-11-12T18:00:00Z')
test('personal 333 plan keeps 72 work sets and rotates only company sessions', () => {
  const company = templates.filter(t => Number.isInteger(t.rotation_order)).sort((a,b)=>a.rotation_order-b.rotation_order)
  const home = templates.filter(t => t.id.startsWith('personal-home-'))
  const weekend = templates.filter(t => t.id.startsWith('personal-weekend-'))
  const sum = rows => rows.reduce((n,t)=>n+templateCounts(t).work,0)
  assert.equal(company.length,4); assert.equal(home.length,4)
  assert.equal(sum(company),36); assert.equal(sum(home),36); assert.equal(sum(weekend),14)
  assert.deepEqual(company.map(templateCounts).map(x=>x.work),[9,9,9,9])
  assert.deepEqual(home.map(templateCounts).map(x=>x.work),[9,9,9,9])
  for (const t of templates) assert.ok(t.exercises.every(m=>exercises.some(e=>e.id===m.exercise_id)))
  const catalog=templates.map(template=>({template}))
  const done=record('done','2026-11-01',[row(100,8)]); done.session.template_id=company[1].id
  const household=record('home','2026-11-02',[row(100,8)]); household.session.template_id=home[2].id
  const backup=record('backup','2026-11-03',[row(100,8)]); backup.session.template_id=weekend[0].id
  const empty=record('empty','2026-11-04',[row(100,8,{completed_at:null})]); empty.session.template_id=company[3].id
  const future=record('future','2099-11-01',[row(100,8)]); future.session.template_id=company[3].id
  assert.equal(nextRoutine(catalog,[done,household,backup,empty,future]).record.template.id,company[2].id)
  assert.equal(nextRoutine(catalog,[]).record.template.id,company[0].id)
})
test('explicit warmups do not inherit heavy work weights; repeat retains warmups and time budget', () => {
  const t = templates[0], previous = record('before', '2026-11-01', [row(100, 10), row(100, 10), row(100, 10)])
  const s = startSession(t, exercises, [previous])
  assert.equal(s.exercises[0].sets[0].warmup, true)
  assert.equal(s.exercises[0].sets[0].weight, 25)
  assert.equal(s.exercises[0].sets[t.exercises[0].warmup_count].weight, 65)
  const late = prefillEmptySession(s, [previous])
  assert.equal(late.exercises[0].sets[0].weight, 25)
  const repeated = sessionTemplate(s)
  assert.equal(repeated.exercises[0].warmup_count, t.exercises[0].warmup_count)
  assert.equal(repeated.duration_max, t.duration_max)
  assert.equal(repeated.notes, t.notes)
})
test('exercise chart normalizes units, excludes drafts, unchecked, warmups, future dates, other modes and preserves same-day workouts', () => {
  const a = record('a', '2026-11-01', [row(50, 8), row(500, 30, { warmup: true }), row(400, 20, { completed_at: null })], 'external', 'kg')
  const b = record('b', '2026-11-01', [row(110.23, 10)])
  const future = record('future', '2026-12-01', [row(900, 20)])
  const active = record('active', '2026-11-02', [row(900, 20)]); active.session.status = 'active'
  const assistance = record('assist', '2026-11-03', [row(40, 12)], 'assistance')
  const points = exercisePoints([a,b,future,active,assistance], 'barbell-bench-press', { now })
  assert.equal(points.length, 2); assert.equal(points[0].peak, 110.23)
  assert.equal(points[0].workSets, 1)
  const reps = metricPoints(points, 'reps', 110.23)
  assert.deepEqual(reps.map(p => p.value), [8,10])
  assert.equal(exercisePoints([a], 'barbell-bench-press', { now, days: 4 }).length, 0)
})
test('assistance uses minimum load, bodyweight uses best reps, and same-load metric never falls back to a different load', () => {
  const assisted = record('a', '2026-11-01', [row(60,10), row(40,8)], 'assistance')
  assert.equal(exercisePoints([assisted], 'barbell-bench-press', { now, mode: 'assistance' })[0].peak, 40)
  const bw = record('bw', '2026-11-01', [row(null,10), row(null,12)], 'bodyweight')
  assert.equal(exercisePoints([bw], 'barbell-bench-press', { now, mode: 'bodyweight' })[0].peak, 12)
  assert.deepEqual(metricPoints(exercisePoints([assisted], 'barbell-bench-press', { now, mode: 'assistance' }), 'reps', 99), [])
})
test('full history merge prefers local edits and removes tombstones and duplicate archive hints', () => {
  const a = record('a', '2026-11-01', [row(100,8)])
  const edited = structuredClone(a); edited.session.exercises[0].sets[0].reps = 10
  const deleted = record('gone', '2026-11-02', [row(100,8)])
  const imported = record('imported:old', '2026-11-03', [row(100,8)])
  const result = mergeExerciseHistory([a,deleted], [edited,imported], new Set(['gone']))
  assert.equal(result.length, 1); assert.equal(result[0].session.exercises[0].sets[0].reps, 10)
})
test('post workout review uses saved targets and complete work sets, without inventing targets for legacy or empty records', () => {
  const current = record('now', '2026-11-10', [row(50,5,{warmup:true}),row(100,12),row(100,8),row(100,8,{completed_at:null})]).session
  current.duration_min = 30; current.duration_max = 40
  current.exercises[0].prescription = { policy:'double', rep_min:8,rep_max:12,increment:5,work_sets:3 }
  const review = sessionReview(current, [])
  assert.equal(review.completed,2); assert.equal(review.planned,3); assert.equal(review.warmup,1)
  assert.deepEqual(review.items[0].drop, {first:12,last:8,weight:100})
  assert.equal(review.items[0].target.top,1)
  assert.equal(review.items[0].next.action,'hold')
  assert.match(review.items[0].next.reason,/尚未全部完成/)
  current.exercises[0].prescription = null
  assert.equal(sessionReview(current, []).items[0].target,null)
  current.exercises[0].sets.forEach(s=>s.completed_at=null)
  assert.equal(sessionReview(current, []).completed,0)
  assert.equal(sessionReview(current, []).items[0].next,null)
})
