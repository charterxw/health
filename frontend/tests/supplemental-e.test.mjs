import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { groupTemplates, filterTemplates, templateCategory } from '../src/training/templateLibrary.js'
import { nextRoutine, templateCounts } from '../src/training/programs.js'
import { startSession, setValue } from '../src/training/strength.js'
import { buildTrainingReport } from '../src/training/report.js'
import { weeklyMuscles } from '../src/training/muscles.js'

const load = name => JSON.parse(readFileSync(new URL(`../../backend/app/data/${name}.json`, import.meta.url)))
const supplemental = load('supplemental_programs'), exercises = load('exercises')

test('E pairs company and home, is searchable and does not change the ABCD cycle', () => {
  const catalog = [...load('programs'), ...supplemental].map(template => ({ template, version: 1 }))
  const group = groupTemplates(catalog).find(g => g.letter === 'E')
  assert.equal(group.records.length, 2)
  assert.match(group.locations, /公司.*居家/)
  assert.deepEqual(supplemental.map(templateCategory), ['company', 'home'])
  assert.deepEqual(filterTemplates(catalog, exercises, { query: 'E' }).map(r => r.template.id), supplemental.map(t => t.id))
  assert.equal(filterTemplates(catalog, exercises, { query: 'E', category: 'company' }).length, 1)
  const cycle = nextRoutine(catalog, [])
  assert.equal(cycle.cycle.length, 4)
  assert.equal(cycle.record.template.rotation_order, 0)
  assert.deepEqual(supplemental.map(templateCounts).map(n => [n.work, n.warmup]), [[9, 1], [9, 0]])
})

test('E starts with correct repetitions, rest, bilateral rounds and no invented loads', () => {
  const session = startSession(supplemental[0], exercises)
  assert.deepEqual(session.exercises.map(m => m.rest_seconds), [90, 60, 60])
  assert.deepEqual(session.exercises.map(m => m.sets.length), [4, 3, 3])
  const pallof = session.exercises[1]
  assert.match(pallof.weight_note, /每侧.*左右两侧/)
  assert.ok(pallof.sets.every(s => s.reps === 10 && s.weight === null))
  assert.ok(session.exercises[0].sets[0].warmup)
})

test('E plank uses seconds, and completed timed work counts in reports and muscle totals', () => {
  const session = startSession(supplemental[1], exercises)
  const now = new Date(), ended = new Date(+now - 60000)
  Object.assign(session, { status: 'completed', started_at: new Date(+ended - 20 * 60000).toISOString(), ended_at: ended.toISOString() })
  const plank = session.exercises[1]
  assert.equal(plank.tracking, 'duration')
  assert.ok(plank.sets.every(s => s.duration_seconds === 30 && s.reps === null && s.weight === null))
  for (const m of session.exercises) for (const s of m.sets) {
    s.completed_at = ended.toISOString()
    if (m.load_mode === 'external') s.weight = 10
    assert.ok(setValue(m, s) > 0)
  }
  assert.equal(buildTrainingReport(session, []).workSets, 9)
  const weekly = weeklyMuscles([{ session }], exercises, now, session.timezone)
  assert.equal(weekly.sets, 9)
  assert.equal(weekly.load.abs, 6)
  assert.equal(weekly.load.calves, 3)
})
