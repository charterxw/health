import test from 'node:test'
import assert from 'node:assert/strict'
import React, { act, useState } from 'react'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'
import { finishSession, startSession, STORE_KEY } from '../src/training/strength.js'

test('activity merges saved records and opens App workout reports without loading AI analysis', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/#workout', pretendToBeVisual: true })
  const { window } = dom
  const { document } = window
  window.scrollTo = () => {}
  window.__HEALTH_NATIVE__={version:1,capabilities:['chrome-v1']}
  window.webkit={messageHandlers:{healthNative:{postMessage:async()=>({})}}}
  const previous = new Map()
  const requests = []
  const session = { ...finishSession(startSession(null, []), 'completed'), title: 'App 新训练',
    started_at: '2026-11-09T15:00:00Z', ended_at: '2026-11-09T15:30:00Z', timezone: 'UTC' }
  window.localStorage.setItem(STORE_KEY, JSON.stringify({ [session.id]: { session, version: 1, dirty: true } }))
  const archive = { title: '历史卧推', datestr: '2023-06-01', localid: 'old', duration_minutes: 38, movements: [] }
  const ok = data => ({ ok: true, status: 200, json: async () => data })
  const fetch = async (url, options = {}) => {
    requests.push(url)
    if (url === '/api/strength/catalog') return ok({ exercises: [], templates: [] })
    if (url === '/api/strength/sessions' || url === '/api/strength/session-deletions' || url.includes('archive?days=')) return ok([])
    if (url === '/api/workouts/archive') return ok({
      training: [archive],
      exercises: [{ date: '2026-11-09', time: '19:00', name: 'WALKING', duration_minutes: 22 }],
    })
    if (options.method === 'PUT') return ok({ session, version: 2 })
    throw new Error(`Unexpected request: ${url}`)
  }
  for (const [key, value] of Object.entries({ window, document, navigator: window.navigator, localStorage: window.localStorage,
    HTMLElement: window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true, fetch })) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key))
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
  }
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error' })
  const { createRoot } = await import('react-dom/client')
  const root = createRoot(document.getElementById('root'))
  try {
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    function Harness() {
      const [tab, setTab] = useState('workout')
      return React.createElement(StrengthTraining, { active: tab === 'strength', showRecords: tab === 'workout',
        onOpenTraining: () => setTab('strength'), onReturnToRecords: () => setTab('workout') })
    }
    const click = async (selector, label) => {
      const button = [...document.querySelectorAll(selector)].find(node => node.textContent.includes(label))
      assert.ok(button, label)
      await act(async () => button.click())
    }
    await act(async () => root.render(React.createElement(Harness)))
    assert.deepEqual([...document.querySelectorAll('[aria-label="运动记录"] .st-history-card strong')]
      .map(node => node.textContent), ['步行', 'App 新训练', '历史卧推'])
    assert.match(document.querySelector('[aria-label="运动记录"]').textContent, /App 新训练.*待同步/)
    assert.equal(document.querySelector('[aria-label="记录来源"]'), null)
    assert.ok(!requests.includes('/api/workouts/exercises'))
    assert.ok(!requests.includes('/api/insights/training?history=true'))
    await click('[aria-label="运动记录"] button', '历史卧推')
    assert.match(document.querySelector('[role="dialog"]').textContent, /2023-06-01/)
    await click('[role="dialog"] button[aria-label="关闭"]', '')
    await click('[aria-label="运动记录"] button', 'App 新训练')
    assert.equal(document.querySelector('[aria-label="运动记录"]').hidden,true)
    assert.equal(document.querySelector('.st-report-overview h2').textContent, 'App 新训练')
    // Some embedded browsers accept back() but never emit popstate.
    const historyBack=window.history.back
    window.history.back=()=>{}
    await click('.st-back', '返回运动记录')
    await act(async()=>new Promise(r=>setTimeout(r,20)))
    assert.equal(document.querySelector('[aria-label="运动记录"]').hidden,false)
    await click('[aria-label="运动记录"] button','App 新训练')
    await act(async()=>window.dispatchEvent(new window.CustomEvent('health-native-action',{detail:{type:'back',sessionID:session.id}})))
    assert.equal(document.querySelector('[aria-label="运动记录"]').hidden,false)
    window.history.back=historyBack
    assert.ok(requests.every(url=>!url.includes('/physiology')))
    assert.deepEqual([...document.querySelectorAll('[aria-label="力量训练页面"] button')].map(node => node.textContent),
      [])
    assert.equal(document.querySelector('[aria-label="运动记录页面"]'), null)
    assert.ok(requests.every(url => !url.includes('/training/sync') && !url.startsWith('/api/insights/')))
  } finally {
    await act(async () => root.unmount())
    await vite.close()
    window.close()
    for (const [key, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor)
      else delete globalThis[key]
    }
  }
})
