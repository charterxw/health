import test from 'node:test'
import assert from 'node:assert/strict'
import React, { act, useState } from 'react'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'
import { startSession } from '../src/training/strength.js'

// DOM integration only: no browser engine or phone rendering is simulated.
test('mobile shell keeps the workout header outside scrolling content and resets page transitions', async () => {
  const dom = new JSDOM('<!doctype html><html><body><div id="test-root"></div></body></html>', { url: 'http://localhost/' })
  const win = dom.window
  win.matchMedia = query => Object.assign(new win.EventTarget(), { matches: query.includes('max-width') })
  Object.defineProperty(win, 'visualViewport', { value: Object.assign(new win.EventTarget(), { height: 852, scale: 1 }) })
  Object.defineProperty(win, 'innerHeight', { value: 852 })
  win.scrollTo = () => {}
  win.HTMLElement.prototype.scrollTo = function ({ top }) { this.scrollTop = top }
  const previous = new Map()
  const setGlobal = (key, value) => {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key))
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
  }
  for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, localStorage: win.localStorage, HTMLElement: win.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true })) setGlobal(key, value)
  const exercise = { id: 'pulldown', name: '单手下拉', muscles: ['背部'], equipment: '绳索', load_mode: 'external' }
  const template = { id: 'back', name: '背部训练', exercises: [{ exercise_id: exercise.id, set_count: 4, rest_seconds: 90, unit: 'lb', target_reps: 8 }] }
  const catalog = { exercises: [exercise], templates: [{ template, version: 1 }] }
  const previousSession = startSession(template, [exercise])
  previousSession.status = 'completed'
  previousSession.started_at = '2026-11-01T12:00:00Z'; previousSession.ended_at = '2026-11-01T12:20:00Z'
  previousSession.exercises[0].sets.forEach(row => { row.weight = 50; row.reps = 8; row.completed_at = '2026-11-01T12:05:00Z' })
  setGlobal('fetch', async (url, options = {}) => {
    let data
    if (url === '/api/strength/catalog') data = catalog
    else if (url === '/api/strength/sessions') data = [{ session: previousSession, version: 1 }]
    else if (url === '/api/strength/session-deletions') data = []
    else if (url.startsWith('/api/workouts/training')) data = []
    else if (options.method === 'PUT' && url.startsWith('/api/strength/sessions/')) {
      const body = JSON.parse(options.body)
      data = { session: body.session, version: body.expected_version + 1 }
    } else throw new Error(`Unexpected test request: ${url}`)
    return { ok: true, status: 200, json: async () => data }
  })
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })
  let root
  try {
    const { createRoot } = await import('react-dom/client')
    const { default: HealthShell } = await vite.ssrLoadModule('/src/components/HealthShell.jsx')
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    function Harness() {
      const [tab, setTab] = useState('strength')
      return React.createElement(HealthShell, { activeTab: tab, setActiveTab: setTab, authed: true },
        React.createElement('div', { hidden: tab !== 'strength' }, React.createElement(StrengthTraining, { active: tab === 'strength' })))
    }
    root = createRoot(win.document.getElementById('test-root'))
    await act(async () => root.render(React.createElement(Harness)))
    const content = win.document.querySelector('.health-page-content')
    const header = win.document.querySelector('.health-training-header')
    const button = text => [...win.document.querySelectorAll('button')].find(node => node.textContent.trim() === text)
    const click = async node => { assert.ok(node); await act(async () => node.dispatchEvent(new win.MouseEvent('click', { bubbles: true }))) }
    assert.equal(header.childElementCount, 0)
    assert.ok(content.querySelector('.st-template-grid'))
    content.scrollTop = 180
    await click(button('开始训练'))
    assert.equal(content.scrollTop, 0)
    assert.ok(header.querySelector('[aria-label="正在进行的训练"]'))
    assert.equal(content.querySelector('.st-session-toolbar'), null)
    assert.ok(content.querySelector('.st-workout-navigation'))
    assert.equal(win.document.querySelectorAll('.st-session-toolbar').length, 1)
    assert.equal(content.querySelectorAll('.st-set-row').length, 4)
    assert.equal(content.querySelector('.st-fill-following'), null)

    const input = content.querySelector('[aria-label="单手下拉第1组次数"]')
    await act(async () => {
      input.dispatchEvent(new win.Event('pointerdown', { bubbles: true }))
      input.focus()
      win.visualViewport.height = 390
      win.visualViewport.dispatchEvent(new win.Event('resize'))
    })
    assert.equal(win.document.documentElement.style.getPropertyValue('--keyboard-viewport-height'), '390px')
    input.setSelectionRange(0, 0)
    await click(input)
    assert.equal(input.selectionStart, 0)
    assert.equal(input.selectionEnd, input.value.length)
    await act(async () => input.blur())
    assert.equal(win.document.documentElement.style.getPropertyValue('--keyboard-viewport-height'), '')
    assert.equal(content.querySelector('.st-fill-following'), null)

    const enter = async (node, value) => act(async () => {
      Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, 'value').set.call(node, value)
      node.dispatchEvent(new win.Event('input', { bubbles: true }))
    })
    const secondWeight = content.querySelector('[aria-label="单手下拉第2组重量 磅"]')
    const secondReps = content.querySelector('[aria-label="单手下拉第2组次数"]')
    assert.equal(secondWeight.value, '50')
    await act(async () => secondWeight.focus())
    assert.equal(content.querySelector('.st-fill-following'), null)
    await enter(secondWeight, '50.0')
    assert.equal(content.querySelector('.st-fill-following'), null)
    await enter(secondWeight, '70')
    assert.ok(button('应用到后续 2 组'))
    await enter(secondWeight, '50')
    assert.equal(content.querySelector('.st-fill-following'), null)
    await act(async () => secondWeight.blur())
    await enter(secondReps, '10')
    assert.ok(button('应用到后续 2 组'))
    await click(button('应用到后续 2 组'))
    assert.equal(content.querySelector('.st-fill-following'), null)
    assert.equal(content.querySelector('[aria-label="单手下拉第3组次数"]').value, '10')
    assert.equal(content.querySelector('[aria-label="单手下拉第4组次数"]').value, '10')
    await act(async () => input.focus())
    assert.equal(content.querySelector('.st-fill-following'), null)
    await act(async () => input.blur())
    await enter(content.querySelector('[aria-label="单手下拉第3组重量 磅"]'), '70')
    await enter(content.querySelector('[aria-label="单手下拉第4组重量 磅"]'), '70')
    await enter(secondWeight, '70')
    assert.equal(content.querySelector('.st-fill-following'), null)

    await click(button('训练笔记'))
    const notes = win.document.querySelector('textarea[aria-label="训练笔记"]')
    assert.ok(notes)
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(win.HTMLTextAreaElement.prototype, 'value').set
      setter.call(notes, '今天第四组保持动作稳定')
      notes.dispatchEvent(new win.Event('input', { bubbles: true }))
    })
    await click(button('完成'))
    await click(button('训练笔记'))
    assert.equal(win.document.querySelector('textarea[aria-label="训练笔记"]').value, '今天第四组保持动作稳定')
    await click(win.document.querySelector('[role="dialog"] [aria-label="关闭"]'))
    await click(button('···更多操作'))
    await click(button('放弃本次训练'))
    assert.equal(win.document.querySelector('[role="dialog"] h2').textContent, '放弃本次训练？')
    await click(button('继续记录'))
    assert.ok(win.document.querySelector('.st-live-view'))
    assert.equal(content.querySelectorAll('.st-set-row').length, 4)

    content.scrollTop = 250
    await click(header.querySelector('[aria-label="返回模板，训练记录会保留"]'))
    assert.equal(content.scrollTop, 0)
    assert.equal(header.childElementCount, 0)
    assert.ok(content.querySelector('.st-resume'))
    await click(content.querySelector('.st-resume'))
    assert.ok(header.querySelector('.st-session-toolbar'))
    content.scrollTop = 120
    await click(win.document.querySelector('.health-nav-item'))
    assert.equal(header.childElementCount, 0)
    assert.equal(content.scrollTop, 0)
    assert.equal(win.document.querySelector('.st-live-view'), null)
    assert.equal(win.document.documentElement.style.getPropertyValue('--keyboard-viewport-height'), '')
    await act(async () => root.unmount())
    root = null
    assert.equal(win.document.documentElement.style.getPropertyValue('--keyboard-viewport-height'), '')
  } finally {
    if (root) await act(async () => root.unmount())
    await vite.close()
    dom.window.close()
    for (const [key, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor)
      else delete globalThis[key]
    }
  }
})
