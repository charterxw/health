import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import React, { act, useState } from 'react'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'
import { startSession, STORE_KEY } from '../src/training/strength.js'

// Verifies real React state/DOM + bridge contracts, not UIKit rendering or glass.
test('native tabs, commands, menus and confirmations preserve the active workout and distinguish screen state', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://health.frankandpatrick.com/#strength', pretendToBeVisual: true })
  const win = dom.window, previous = new Map(), calls = []
  win.matchMedia = () => Object.assign(new win.EventTarget(), { matches: true })
  win.scrollTo = () => {}; win.HTMLElement.prototype.scrollTo = function ({ top }) { this.scrollTop = top }
  let confirmed = false, selected = null, signedOut = false
  win.__HEALTH_NATIVE__ = { version: 1, capabilities: ['chrome-v1', 'menus-v1'] }
  win.webkit = { messageHandlers: { healthNative: { postMessage: async body => {
    calls.push(body)
    if (body.type === 'syncChrome') return { nativeChromeVersion: 1 }
    if (body.type === 'presentMenu') return { selected }
    if (body.type === 'presentConfirmation') return { confirmed }
    return { synced: true }
  } } } }
  const set = (key, value) => { previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key)); Object.defineProperty(globalThis, key, { configurable: true, writable: true, value }) }
  for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, localStorage: win.localStorage,
    HTMLElement: win.HTMLElement, MutationObserver: win.MutationObserver, IS_REACT_ACT_ENVIRONMENT: true })) set(key, value)
  const exercises = ['单手下拉', '宽距高位下拉'].map((name, index) => ({ id: `move${index}`, name, muscles: ['背'], equipment: '绳索', load_mode: 'external' }))
  const template = { id: 'back', name: '背部训练', exercises: exercises.map(e => ({ exercise_id: e.id, set_count: 4, rest_seconds: 90, unit: 'lb', target_reps: 8 })) }
  const session = startSession(template, exercises)
  session.exercises.forEach(m => m.sets.forEach(s => { s.weight = 50; s.reps = 8 }))
  const ok = data => ({ ok: true, status: 200, json: async () => data })
  set('fetch', async (url, options = {}) => {
    if (url === '/api/strength/catalog') return ok({ exercises, templates: [{ template, version: 1 }] })
    if (url === '/api/strength/sessions') return ok([{ session, version: 1 }])
    if (url === '/api/strength/session-deletions' || url.startsWith('/api/workouts/training')) return ok([])
    if (options.method === 'PUT') { const value = JSON.parse(options.body); return ok({ session: value.session, version: value.expected_version + 1 }) }
    if (url.endsWith('/physiology')) return ok({ status: 'pending', metrics: {}, heart_rate: null })
    throw new Error(`Unexpected test request: ${url}`)
  })
  const style = win.document.createElement('style')
  style.textContent = await fs.readFile(new URL('../src/shell.css', import.meta.url), 'utf8'); win.document.head.append(style)
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })
  let root
  try {
    const { createRoot } = await import('react-dom/client')
    const { default: HealthShell } = await vite.ssrLoadModule('/src/components/HealthShell.jsx')
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    function Harness() {
      const [tab, setTab] = useState('strength')
      return React.createElement(HealthShell, { activeTab: tab, setActiveTab: setTab, authed: true, onSignOut: () => { signedOut = true } },
        React.createElement('div', { hidden: tab !== 'strength' }, React.createElement(StrengthTraining, { active: tab === 'strength' })))
    }
    root = createRoot(win.document.getElementById('root'))
    await act(async () => root.render(React.createElement(Harness)))
    const click = async node => { assert.ok(node); await act(async () => node.click()) }
    const command = async detail => act(async () => win.dispatchEvent(new win.CustomEvent('health-native-action', { detail })))
    const chrome = () => calls.filter(c => c.type === 'syncChrome').at(-1)?.chrome
    const workout = () => calls.filter(c => c.type === 'syncWorkout').at(-1)?.workout
    const saved = () => JSON.parse(localStorage.getItem(STORE_KEY))[session.id].session
    assert.equal(chrome().screen, 'home'); assert.equal(workout().sessionID, session.id)
    assert.equal(win.document.documentElement.classList.contains('health-native-chrome'), true)
    assert.equal(win.getComputedStyle(win.document.querySelector('.health-navigation')).display, 'none')
    assert.equal(win.getComputedStyle(win.document.querySelector('.health-page-header')).display, 'none')
    await click(win.document.querySelector('.st-resume'))
    assert.equal(chrome().screen, 'workout'); assert.equal(chrome().workoutID, session.id)
    assert.equal(win.document.querySelectorAll('.st-set-row').length, 4)
    assert.equal(win.getComputedStyle(win.document.querySelector('.st-live-topline')).display, 'none')
    await click(win.document.querySelector('[aria-label="完成单手下拉第1组"]'))
    assert.equal(saved().exercises[0].sets[0].completed_at !== null, true)
    await command({ type: 'back', sessionID: session.id })
    assert.equal(chrome().screen, 'home'); assert.equal(workout().completedSets, 1)
    await command({ type: 'selectTab', tab: 'sleep' })
    assert.equal(chrome().tab, 'sleep'); assert.equal(chrome().screen, 'home'); assert.equal(chrome().workoutID, null)
    assert.equal(workout().sessionID, session.id)
    await command({ type: 'selectTab', tab: 'not-a-page' }); assert.equal(chrome().tab, 'sleep')
    await command({ type: 'selectTab', tab: 'strength' }); await click(win.document.querySelector('.st-resume'))
    assert.equal(saved().exercises[0].sets[0].weight, 50)
    await command({ type: 'renameWorkout', sessionID: session.id, title: '背部 · 原生测试' })
    assert.equal(chrome().title, '背部 · 原生测试')
    const before = calls.length
    await act(async () => win.document.querySelector('.st-save-state').append(win.document.createTextNode(' ')))
    assert.equal(calls.length, before) // Timer/text mutations do not send navigation ticks.
    selected = session.exercises[1].id
    await click(win.document.querySelector('.st-exercise-switch'))
    assert.equal(workout().movementIndex, 2)
    selected = 'edit'; await click(win.document.querySelector('.st-more'))
    assert.equal(chrome().webDialogOpen, true)
    const restInput = win.document.querySelector('#st-rest-seconds')
    const typeRest = async value => act(async () => {
      Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, 'value').set.call(restInput, value)
      restInput.dispatchEvent(new win.Event('input', { bubbles: true }))
    })
    await act(async () => restInput.focus())
    await typeRest('0')
    assert.equal(saved().exercises[1].rest_seconds, 0)
    await typeRest('')
    assert.equal(restInput.value, '')
    assert.equal(saved().exercises[1].rest_seconds, 0)
    await typeRest('75')
    assert.equal(restInput.value, '75')
    await typeRest('750')
    assert.equal(restInput.value, '75')
    assert.equal(saved().exercises[1].rest_seconds, 75)
    await typeRest('')
    await act(async () => restInput.blur())
    assert.equal(restInput.value, '75')
    await click(win.document.querySelector('.st-modal header button'))
    assert.equal(chrome().webDialogOpen, false)
    const prompts = calls.filter(c => c.type === 'presentConfirmation').length
    await command({ type: 'finishWorkout', sessionID: '11111111-2222-4333-8444-555555555555' })
    assert.equal(calls.filter(c => c.type === 'presentConfirmation').length, prompts)
    await command({ type: 'finishWorkout', sessionID: session.id })
    assert.equal(saved().status, 'active'); assert.equal(win.document.querySelector('.st-modal'), null)
    confirmed = true; await command({ type: 'finishWorkout', sessionID: session.id })
    assert.equal(saved().status, 'completed'); assert.equal(workout(), null)
    assert.equal(chrome().screen, 'report'); assert.equal(chrome().workoutID, session.id)
    assert.equal(chrome().title, '训练总结')
    await command({ type: 'back', sessionID: session.id })
    assert.equal(chrome().screen, 'home')
    await command({ type: 'signOut' }); assert.equal(signedOut, true)
  } finally {
    if (root) await act(async () => root.unmount())
    await vite.close(); dom.window.close()
    for (const [key, descriptor] of previous) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key] }
  }
})
