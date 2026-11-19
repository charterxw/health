import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import React from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { createServer } from 'vite'
import { STORE_KEY, CATALOG_KEY, startSession, finishSession, appendExerciseSet, fillFollowingSets, prefillEmptySession } from '../src/training/strength.js'
import { buildTrainingReport } from '../src/training/report.js'
import { sessionReview } from '../src/training/review.js'
import { weeklyMuscles } from '../src/training/muscles.js'
import { exercisePoints } from '../src/training/exerciseProgress.js'
import { nextRoutine, sessionTemplate } from '../src/training/programs.js'

const exercises = JSON.parse(await readFile(new URL('../../backend/app/data/posture_exercises.json', import.meta.url)))
const programs = JSON.parse(await readFile(new URL('../../backend/app/data/posture_programs.json', import.meta.url)))

test('daily posture records seconds separately, survives repeat/prefill, and stays outside strength volume and rotation', () => {
  const session = startSession(programs[0], exercises)
  const stretch = session.exercises[2]
  assert.equal(stretch.sets[0].duration_seconds, 25)
  assert.equal(stretch.sets[0].reps, null)
  stretch.sets[0].duration_seconds = 30
  assert.equal(fillFollowingSets(stretch, stretch.sets[0].id).sets[1].duration_seconds, 30)
  assert.equal(appendExerciseSet(stretch, stretch.sets[0].id).sets.at(-1).duration_seconds, 30)
  const at = new Date().toISOString()
  for (const m of session.exercises.slice(0, 4)) for (const s of m.sets) s.completed_at = at
  const done = finishSession(session, 'completed', at), history = [{ session: done }]
  const report = buildTrainingReport(done, [])
  assert.equal(report.workSets, 6) // Optional chin tucks may remain unchecked.
  assert.equal(report.totalReps, 18) // Stretch seconds never become repetitions.
  assert.equal(sessionReview(done, []).completed, 6)
  assert.equal(weeklyMuscles(history, exercises).sets, 0)
  assert.equal(nextRoutine(programs.map(template => ({ template })), history), null)
  assert.equal(sessionTemplate(done).exercises[2].target_seconds, 30)
  const empty = startSession(programs[0], exercises)
  empty.started_at = new Date(Date.parse(at) + 1000).toISOString()
  empty.exercises[2].sets.forEach(s => { s.duration_seconds = null })
  assert.equal(prefillEmptySession(empty, history).exercises[2].sets[0].duration_seconds, 30)
  const points = exercisePoints(history, stretch.exercise_id, { mode: 'bodyweight', now: new Date(Date.parse(at) + 2000), timezone: session.timezone })
  assert.equal(points[0].peak, 30)
  assert.equal(points[0].sets[0].duration_seconds, 30)
})

test('restored timed workout and its report show seconds, without weight or repetition inputs', async () => {
  const session = startSession(programs[0], exercises)
  session.exercises[0].sets[0].completed_at = session.started_at
  session.exercises[1].sets[0].completed_at = session.started_at
  const cache = { [CATALOG_KEY]: JSON.stringify({ exercises, templates: programs.map(template => ({ template, version: 1 })) }),
    [STORE_KEY]: JSON.stringify({ [session.id]: { session, version: 1, dirty: false } }) }
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'localStorage')
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: { getItem: key => cache[key] || null } })
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })
  try {
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    const page = renderToStaticMarkup(React.createElement(StrengthTraining, { active: true }))
    assert.match(page, /门框胸肌拉伸 · 左侧第1组时长 秒/)
    assert.match(page, /时长 \/ 秒/)
    assert.doesNotMatch(page, /门框胸肌拉伸 · 左侧第1组(?:重量|次数)/)
    session.exercises[2].sets[0].completed_at = session.started_at
    const completed = finishSession(session)
    const { default: TrainingReport } = await vite.ssrLoadModule('/src/components/TrainingReport.jsx')
    const report = renderToStaticMarkup(React.createElement(TrainingReport, { session: completed, history: [], savedText: '已保存', serverSaved: false }))
    assert.match(report, /25 秒/)
    assert.match(report, /时长 \/ 秒/)
    assert.doesNotMatch(report, /自重 × null|保持重量继续补次数/)
  } finally {
    await vite.close()
    if (previous) Object.defineProperty(globalThis, 'localStorage', previous)
    else delete globalThis.localStorage
  }
})
