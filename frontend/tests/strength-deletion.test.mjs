import test from 'node:test'
import assert from 'node:assert/strict'
import React, { act, useState } from 'react'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'
import { STORE_KEY, CATALOG_KEY, DELETIONS_KEY, startSession } from '../src/training/strength.js'

async function setup() {
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true })
  const win = dom.window, previous = new Map()
  win.scrollTo = () => {}
  win.HTMLElement.prototype.scrollTo = function ({ top }) { this.scrollTop = top }
  for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, localStorage: win.localStorage, HTMLElement: win.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true })) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key))
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
  }
  previous.set('fetch', Object.getOwnPropertyDescriptor(globalThis, 'fetch'))
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })
  const exercise = { id: 'pulldown', name: '下拉', equipment: '绳索', muscles: ['背'], load_mode: 'external' }
  const template = { id: 'back', name: '背部', exercises: [{ exercise_id: 'pulldown', set_count: 1, unit: 'lb' }] }
  const catalog = { exercises: [exercise], templates: [{ template, version: 1 }] }
  const make = title => {
    const session = startSession(template, [exercise])
    Object.assign(session, { title, status: 'completed', started_at: '2026-11-08T12:00:00Z', ended_at: '2026-11-08T12:05:00Z' })
    Object.assign(session.exercises[0].sets[0], { weight: 50, reps: 8, completed_at: '2026-11-08T12:03:00Z' })
    return { session, version: 1 }
  }
  localStorage.setItem(CATALOG_KEY, JSON.stringify(catalog))
  const { createRoot } = await import('react-dom/client')
  const root = createRoot(win.document.getElementById('root'))
  return { win, root, vite, catalog, make,
    button: text => [...win.document.querySelectorAll('button')].find(node => node.textContent.trim() === text),
    click: async node => { assert.ok(node); await act(async () => {node.click();await new Promise(r=>setTimeout(r,20))}) },
    async close() {
      await act(async () => root.unmount()); await vite.close(); dom.window.close()
      for (const [key, descriptor] of previous) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key] }
    },
  }
}
const ok = data => ({ ok: true, status: 200, json: async () => data })
const emptyArchive = { training: [], exercises: [] }

function RecordTabs({ StrengthTraining, HealthShell }) {
  const [tab, setTab] = useState('workout')
  const training = React.createElement(StrengthTraining, { active: tab === 'strength', showRecords: tab === 'workout',
    onOpenTraining: () => setTab('strength'), onReturnToRecords: () => setTab('workout') })
  return HealthShell ? React.createElement(HealthShell, { activeTab: tab, setActiveTab: setTab, authed: true }, training) : training
}

test('history deletion supports cancel, failure and report deletion, and old cache cannot bring records back', async () => {
  const env = await setup()
  try {
    const { win, root, vite, catalog, make, button, click } = env
    const first = make('实验一'), other = make('保留的训练'), remoteDeleted = make('另一设备已删除')
    localStorage.setItem(DELETIONS_KEY, JSON.stringify(['z-removed', 'a-removed']))
    localStorage.setItem(STORE_KEY, JSON.stringify(Object.fromEntries([first, other, { ...remoteDeleted, dirty: true }].map(r => [r.session.id, r]))))
    let deleted = [{ id: remoteDeleted.session.id, version: 2 }], fail = true
    const deletes = []
    globalThis.fetch = async (url, options = {}) => {
      if (options.method === 'POST' && url.endsWith('/delete')) {
        assert.equal(JSON.parse(options.body).expected_version, 1)
        deletes.push(url)
        if (fail) return { ok: false, status: 503, json: async () => ({ detail: '删除暂时失败，记录仍保留' }) }
        const marker = { id: first.session.id, version: 2 }; deleted.push(marker); return ok(marker)
      }
      if (url === '/api/strength/catalog') return ok(catalog)
      // Deliberately stale response: deleted records still appear in this snapshot.
      if (url === '/api/strength/sessions') return ok([first, other, remoteDeleted])
      if (url === '/api/strength/session-deletions') return ok(deleted)
      if (url === '/api/workouts/archive') return ok(emptyArchive)
      if (url === `/api/strength/sessions/${first.session.id}`) return ok(first)
      if (url.startsWith('/api/workouts/training')) return ok([])
      if (url.endsWith('/physiology')) return ok({ status: 'pending', metrics: {}, heart_rate: null })
      throw new Error(`Unexpected request ${url}`)
    }
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    await act(async () => root.render(React.createElement(RecordTabs, { StrengthTraining })))
    assert.equal(win.document.querySelectorAll('.st-history-card').length, 2)
    assert.doesNotMatch(win.document.body.textContent, /另一设备已删除/)
    const markers = JSON.parse(localStorage.getItem(DELETIONS_KEY))
    assert.deepEqual(markers, [...markers].sort()) // Tabs with different insertion orders converge.
    if(!win.document.querySelector('.st-workout-report'))await click(win.document.querySelector('.st-history-open'))
    await click(button('删除这场训练'))
    assert.match(win.document.querySelector('[role="dialog"]').textContent, /删除这场训练/)
    await click(button('取消'))
    assert.equal(deletes.length, 0)
    await click(win.document.querySelector('.st-history-open'))
    assert.ok(win.document.querySelector('.st-workout-report'))
    await click(button('删除这场训练'))
    await click(button('确认删除'))
    assert.match(win.document.querySelector('[role="alert"]').textContent, /暂未确认删除结果/)
    assert.ok(JSON.parse(localStorage.getItem(STORE_KEY))[first.session.id])
    fail = false
    await click(button('确认删除'))
    assert.equal(win.document.querySelector('[role="dialog"]'), null)
    assert.equal(win.document.querySelector('.st-workout-report'), null)
    assert.equal(win.document.querySelectorAll('.st-history-card').length, 1)
    assert.match(win.document.body.textContent, /保留的训练/)
    assert.equal(JSON.parse(localStorage.getItem(STORE_KEY))[first.session.id], undefined)
    assert.ok(JSON.parse(localStorage.getItem(DELETIONS_KEY)).includes(first.session.id))
    assert.match(deletes.at(-1), /\/delete$/)
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    assert.equal(win.document.querySelectorAll('.st-history-card').length, 1)
  } finally { await env.close() }
})

test('a save response from before an external deletion cannot restore the removed local record', async () => {
  const env = await setup()
  try {
    const { win, root, vite, catalog, make } = env
    const record = make('旧缓存'), id = record.session.id
    localStorage.setItem(STORE_KEY, JSON.stringify({ [id]: { ...record, dirty: true } }))
    let markers = [], resolveSave, store
    globalThis.fetch = async (url, options = {}) => {
      if (options.method === 'PUT') return await new Promise(resolve => { resolveSave = () => resolve(ok({ ...record, version: 2 })) })
      if (url === '/api/strength/catalog') return ok(catalog)
      if (url === '/api/strength/sessions') return ok([record])
      if (url === '/api/strength/session-deletions') return ok(markers)
      if (url.startsWith('/api/workouts/training')) return ok([])
      throw new Error(`Unexpected request ${url}`)
    }
    const { default: useStrengthStore } = await vite.ssrLoadModule('/src/training/useStrengthStore.js')
    function Harness() { store = useStrengthStore(); return null }
    await act(async () => root.render(React.createElement(Harness)))
    let saving
    await act(async () => { saving = store.sync(); await Promise.resolve() })
    assert.equal(typeof resolveSave, 'function')
    markers = [{ id, version: 3 }]
    await act(async () => store.refresh())
    assert.equal(store.records[id], undefined)
    await act(async () => { resolveSave(); await saving })
    assert.equal(store.records[id], undefined)
    assert.equal(JSON.parse(localStorage.getItem(STORE_KEY))[id], undefined)
    await act(async () => store.put(record.session))
    assert.equal(store.records[id], undefined)
  } finally { await env.close() }
})

test('a gone response to an old save clears the local copy even if the deletion feed is unavailable', async () => {
  const env = await setup()
  try {
    const { root, vite, catalog, make } = env
    const record = make('已删的旧记录'), id = record.session.id
    localStorage.setItem(STORE_KEY, JSON.stringify({ [id]: { ...record, dirty: true } }))
    globalThis.fetch = async (url, options = {}) => {
      if (options.method === 'PUT') return { ok: false, status: 410, json: async () => ({ detail: { message: '这场训练已删除', deleted: { id, version: 2 } } }) }
      if (url === '/api/strength/catalog') return ok(catalog)
      if (url === '/api/strength/sessions') return ok([])
      if (url === '/api/strength/session-deletions') return { ok: false, status: 503, json: async () => ({}) }
      if (url.startsWith('/api/workouts/training')) return ok([])
      throw new Error(`Unexpected request ${url}`)
    }
    let store
    const { default: useStrengthStore } = await vite.ssrLoadModule('/src/training/useStrengthStore.js')
    function Harness() { store = useStrengthStore(); return null }
    await act(async () => root.render(React.createElement(Harness)))
    await act(async () => store.sync())
    assert.equal(store.records[id], undefined)
    assert.ok(JSON.parse(localStorage.getItem(DELETIONS_KEY)).includes(id))
  } finally { await env.close() }
})

test('notification link opens the requested report even beyond the recent session list', async () => {
  const env = await setup()
  try {
    const { win, root, vite, catalog, make } = env
    const record = make('通知对应的训练'), id = record.session.id
    win.history.replaceState({}, '', `/?workout=${id}#strength`)
    globalThis.fetch = async url => {
      if (url === '/api/strength/catalog') return ok(catalog)
      if (url === '/api/strength/sessions' || url === '/api/strength/session-deletions' || url.startsWith('/api/workouts/training')) return ok([])
      if (url === `/api/strength/sessions/${id}`) return ok(record)
      if (url.endsWith('/physiology')) return ok({ status: 'pending', metrics: {}, heart_rate: null })
      throw new Error(`Unexpected request ${url}`)
    }
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    await act(async () => root.render(React.createElement(StrengthTraining, { active: true })))
    assert.equal(win.document.querySelector('.st-report-overview h2').textContent, '通知对应的训练')
  } finally { await env.close() }
})

for (const alreadyDeleted of [false, true]) test(`stalled deletion is dismissible and ${alreadyDeleted ? 'a lost success response is reconciled' : 'a timeout releases the controls for retry'}`, async () => {
  const env = await setup()
  const originalTimeout = globalThis.setTimeout
  try {
    const { win, root, vite, catalog, make, click, button } = env
    const record = make('卡住的删除'), id = record.session.id
    let posted = false, deadline
    globalThis.fetch = async (url, options = {}) => {
      if (options.method === 'POST' && url.endsWith('/delete')) { posted = true; return new Promise(() => {}) }
      if (url === `/api/strength/sessions/${id}`) return alreadyDeleted && posted ? { ok: false, status: 404, json: async () => ({ detail: '没有找到这场训练' }) } : ok(record)
      if (url === '/api/strength/catalog') return ok(catalog)
      if (url === '/api/strength/sessions') return ok([record])
      if (url === '/api/workouts/archive') return ok(emptyArchive)
      if (url === '/api/strength/session-deletions' || url.startsWith('/api/workouts/training')) return ok([])
      throw new Error(`Unexpected request ${url}`)
    }
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    await act(async () => root.render(React.createElement(RecordTabs, { StrengthTraining })))
    globalThis.setTimeout = (callback, delay, ...args) => {
      if (delay === 12000) { deadline = callback; const handle = originalTimeout(() => {}, 60000); handle.unref(); return handle }
      return originalTimeout(callback, delay, ...args)
    }
    if(!win.document.querySelector('.st-workout-report'))await click(win.document.querySelector('.st-history-open'))
    await click(button('删除这场训练'))
    await click(button('确认删除'))
    assert.ok(posted)
    assert.equal(button('删除中…').disabled, true)
    assert.equal(button('关闭').disabled, false)
    await click(button('关闭'))
    assert.equal(win.document.querySelector('[role="dialog"]'), null)
    await act(async () => deadline())
    if (alreadyDeleted) {
      assert.equal(win.document.querySelector('.st-history-card'), null)
      assert.ok(JSON.parse(localStorage.getItem(DELETIONS_KEY)).includes(id))
    } else {
      assert.ok(win.document.querySelector('.st-history-card'))
      if(!win.document.querySelector('.st-workout-report'))await click(win.document.querySelector('.st-history-open'))
    await click(button('删除这场训练'))
      assert.equal(button('确认删除').disabled, false)
      await click(button('取消'))
    }
  } finally { globalThis.setTimeout = originalTimeout; await env.close() }
})

test('report notification control exists only inside settings, away from training and reports', async () => {
  const env = await setup()
  try {
    const { win, root, vite, catalog, make, click, button } = env
    win.matchMedia = () => Object.assign(new win.EventTarget(), { matches: false })
    const record = make('设置检查')
    globalThis.fetch = async url => {
      if (url === '/api/strength/catalog') return ok(catalog)
      if (url === '/api/strength/sessions') return ok([record])
      if (url === '/api/workouts/archive') return ok(emptyArchive)
      if (url === '/api/strength/session-deletions' || url.startsWith('/api/workouts/training')) return ok([])
      if (url.endsWith('/physiology')) return ok({ status: 'pending', metrics: {}, heart_rate: null })
      throw new Error(`Unexpected request ${url}`)
    }
    const { default: HealthShell } = await vite.ssrLoadModule('/src/components/HealthShell.jsx')
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    await act(async () => root.render(React.createElement(RecordTabs, { StrengthTraining, HealthShell })))
    assert.equal(win.document.querySelector('.st-webpush'), null)
    await click(win.document.querySelector('[aria-label="设置"]'))
    assert.equal(win.document.querySelector('[role="dialog"] h2').textContent, '设置')
    assert.ok(win.document.querySelector('[role="dialog"] .st-webpush'))
    await click(win.document.querySelector('[role="dialog"] [aria-label="关闭"]'))
    await click(win.document.querySelector('.st-history-open'))
    assert.ok(win.document.querySelector('.st-workout-report'))
    assert.equal(win.document.querySelector('.st-webpush'), null)
  } finally { await env.close() }
})
