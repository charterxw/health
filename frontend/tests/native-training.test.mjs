import test from 'node:test'
import assert from 'node:assert/strict'
import React, { act } from 'react'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'
import { startSession } from '../src/training/strength.js'

test('real training UI syncs native progress/pause/rest/end; permissions stay in settings and require a tap', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://health.frankandpatrick.com/#strength', pretendToBeVisual: true })
  const win = dom.window, previous = new Map(), calls = []
  win.matchMedia = () => Object.assign(new win.EventTarget(), { matches: true })
  win.scrollTo = () => {}
  win.HTMLElement.prototype.scrollTo = function ({ top }) { this.scrollTop = top }
  const status = { activitiesAllowed: true, liveActivitiesEnabled: true, restRemindersEnabled: false, notificationPermission: 'notDetermined' }
  win.__HEALTH_NATIVE__ = { version: 1 }
  win.webkit = { messageHandlers: { healthNative: { postMessage: async body => {
    calls.push(body)
    if (body.type === 'enableRestReminders') Object.assign(status, { restRemindersEnabled: true, notificationPermission: 'authorized' })
    if (body.type === 'disableRestReminders') status.restRemindersEnabled = false
    if (body.type === 'setLiveActivities') status.liveActivitiesEnabled = body.enabled
    return { ...status }
  } } } }
  function set(key, value) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key))
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
  }
  for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator,
    localStorage: win.localStorage, HTMLElement: win.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true })) set(key, value)
  const exercise = { id: 'pulldown', name: '单手下拉', muscles: ['背部'], equipment: '绳索', load_mode: 'external' }
  const template = { id: 'back', name: '背部训练', exercises: [{ exercise_id: exercise.id, set_count: 4, rest_seconds: 90, unit: 'lb', target_reps: 8 }] }
  const session = startSession(template, [exercise])
  session.exercises[0].sets.forEach(row => { row.weight = 50; row.reps = 8 })
  const records = [{ session, version: 1 }]
  const ok = data => ({ ok: true, status: 200, json: async () => data })
  set('fetch', async (url, options = {}) => {
    if (url === '/api/strength/catalog') return ok({ exercises: [exercise], templates: [{ template, version: 1 }] })
    if (url === '/api/strength/sessions') return ok(records)
    if (url === '/api/strength/session-deletions' || url.startsWith('/api/workouts/training')) return ok([])
    if (options.method === 'PUT') { const body = JSON.parse(options.body); return ok({ session: body.session, version: body.expected_version + 1 }) }
    if (url.endsWith('/physiology')) return ok({ status: 'pending', metrics: {}, heart_rate: null })
    if (url.startsWith('/api/strength/sessions/')) return { ok: false, status: 404, json: async () => ({ detail: 'Missing' }) }
    throw new Error(`Unexpected request ${url}`)
  })
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })
  let root
  try {
    const { createRoot } = await import('react-dom/client')
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    const { default: HealthShell } = await vite.ssrLoadModule('/src/components/HealthShell.jsx')
    root = createRoot(win.document.getElementById('root'))
    await act(async () => root.render(React.createElement(HealthShell, { activeTab: 'strength', setActiveTab() {}, authed: true }, React.createElement(StrengthTraining, { active: true }))))
    const click = async node => { assert.ok(node); await act(async () => node.click()) }
    const button = text => [...win.document.querySelectorAll('button')].find(node => node.textContent.trim() === text)
    const sync = () => calls.filter(call => call.type === 'syncWorkout').at(-1)?.workout
    assert.equal(sync().sessionID, session.id)
    assert.equal(sync().plannedSets, 4)
    assert.equal(calls.some(call => call.type === 'enableRestReminders'), false)
    await click(win.document.querySelector('.st-resume'))
    await click(win.document.querySelector('[aria-label="完成单手下拉第1组"]'))
    assert.equal(sync().completedSets, 1)
    assert.ok(sync().restUntil > Date.now() / 1000)
    await click(win.document.querySelector('[aria-label="暂停训练"]'))
    assert.ok(sync().pausedAt)
    await click(win.document.querySelector('[aria-label="继续训练"]'))
    assert.equal(sync().pausedAt, null)
    await click(button('跳过'))
    assert.equal(sync().restUntil, null)
    const beforeResume = calls.length
    await act(async () => win.dispatchEvent(new win.Event('health-native-resume')))
    assert.ok(calls.length > beforeResume)
    assert.equal(sync().sessionID, session.id)
    await click(button('结束')); await click(button('完成并保存'))
    assert.equal(sync(), null)
    await act(async () => win.dispatchEvent(new win.CustomEvent('health-native-open-workout', { detail: '11111111-2222-4333-8444-555555555555' })))
    assert.match(win.document.body.textContent, /这场训练不存在或已删除/)
    await click(win.document.querySelector('[aria-label="设置"]'))
    assert.equal(win.document.querySelector('.st-webpush'), null)
    assert.match(win.document.querySelector('[role="dialog"]').textContent, /组间休息提醒/)
    assert.equal(calls.some(call => call.type === 'enableRestReminders'), false)
    await click(button('开启提醒'))
    assert.equal(calls.filter(call => call.type === 'enableRestReminders').length, 1)
    assert.ok(button('关闭提醒'))
    await click(button('关闭提醒'))
    assert.equal(calls.at(-1).type, 'disableRestReminders')
    await click(button('关闭实况'))
    assert.equal(calls.at(-1).type, 'setLiveActivities')
    assert.equal(calls.at(-1).enabled, false)
  } finally {
    if (root) await act(async () => root.unmount())
    await vite.close(); dom.window.close()
    for (const [key, descriptor] of previous) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key] }
  }
})
