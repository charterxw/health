import test from 'node:test'
import assert from 'node:assert/strict'
import React, { act } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'

const session = { id: 'session-1', started_at: '2026-11-08T12:00:00Z', ended_at: '2026-11-08T12:05:00Z', timezone: 'America/New_York' }
const waiting = { status: 'waiting_sync', attempts: 1, syncing: false, heart_rate: { sources: [], summary: { sample_count: 0 }, chart: [], fetched_at: '2026-11-08T12:05:30Z' }, metrics: { steps: { value: 0 }, active_energy: { value: null } }, next_attempt_at: '2026-11-08T12:06:00Z' }
const collecting = { ...waiting, status: 'pending', attempts: 0, syncing: true, heart_rate: { ...waiting.heart_rate, fetched_at: null }, metrics: {} }
const ready = {
  ...waiting, status: 'partial',
  heart_rate: {
    sources: [{ id: 'air', label: 'Air', count: 24 }], selected_source: { id: 'air', label: 'Air' },
    summary: { sample_count: 24, mean_bpm: 110.5, min_bpm: 90, max_bpm: 155, minutes_with_samples: 3, window_minutes: 5, largest_gap_seconds: 121 },
    chart: [90, 100, null, null, 141.5].map((mean_bpm, i) => ({ at: `2026-11-08T12:0${i}:00Z`, mean_bpm })),
    fetched_at: '2026-11-08T12:07:00Z',
  },
  metrics: { steps: { value: 0 }, active_energy: { value: 25.8 } },
  daily_context: { sleep_hours: 7.2, hrv: 43, resting_hr: null, cached_at: '2026-11-08 11:00:00' },
}
const makeVite = () => createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })

test('health report distinguishes missing values from zero and leaves chart gaps instead of joining them', async () => {
  const vite = await makeVite()
  try {
    const { PhysiologyView } = await vite.ssrLoadModule('/src/components/WorkoutPhysiology.jsx')
    const render = data => renderToStaticMarkup(React.createElement(PhysiologyView, { data, timezone: session.timezone }))
    const pending = render(waiting)
    assert.match(pending, /等待设备数据同步/)
    assert.match(pending, /href="https:\/\/www.fitbit.com\/in-app\/today" target="_blank"/)
    assert.match(pending, /打开 Google Health 同步/)
    assert.doesNotMatch(pending, /步数|平均心率|估算活动热量|<svg/)
    assert.match(render({ ...waiting, metrics: { active_energy: { value: 0 } } }), /<dd>0<small> 千卡/)
    for (const data of [null, { ...waiting, status: 'pending', attempts: 0, syncing: true, heart_rate: null },
      { ...waiting, attempts: 1, syncing: true, checked_at: '2026-11-08T12:05:20Z', heart_rate: { ...waiting.heart_rate, fetched_at: null } },
      { ...ready, status: 'ready' }, { ...ready, status: 'connection_required', errors: { heart_rate: 'connection_required' } },
      { ...waiting, status: 'unsupported' }]) {
      assert.doesNotMatch(render(data), /class="st-open-health"/)
    }
    // A previous empty result keeps its fallback during later background retries.
    assert.match(render({ ...waiting, attempts: 2, syncing: true }), /class="st-open-health"/)
    assert.match(render({ ...waiting, status: 'error', heart_rate: null, errors: { heart_rate: 'temporarily_unavailable' } }), /class="st-open-health"/)
    assert.doesNotMatch(renderToStaticMarkup(React.createElement(PhysiologyView, { data: waiting, serverSaved: false, timezone: session.timezone })), /class="st-open-health"/)
    const report = render(ready)
    assert.match(report, /^<details class="st-physiology"/)
    assert.match(report, /部分心率数据/)
    assert.match(report, /110.5/)
    assert.match(report, /估算活动热量<\/dt><dd>25.8/)
    assert.doesNotMatch(report, /步数|分钟有样本|最大间隔|暂停时间|当天恢复背景|静息心率/)
    assert.equal((report.match(/<polyline/g) || []).length, 1)
    assert.equal((report.match(/<circle/g) || []).length, 1)
    const marked = renderToStaticMarkup(React.createElement(PhysiologyView, { data: ready, timezone: session.timezone,
      endedAt: session.ended_at, marks: [
        { id: 'start', at: session.started_at, name: '杠铃卧推', opening: true },
        { id: 'later1', at: '2026-11-08T12:02:30Z', name: '上斜哑铃卧推' },
        { id: 'later2', at: '2026-11-08T12:02:31Z', name: '绳索侧平举' },
        { id: 'outside', at: '2026-11-08T12:06:00Z', name: '超出时段', set: 1, result: '50 磅 × 8' },
      ],
    }))
    assert.match(marked, /x1="182" x2="182" y1="17" y2="114" class="st-heart-set-line"/)
    assert.equal((marked.match(/class="st-heart-set-line"/g) || []).length, 2)
    assert.match(marked, /07:00:00<\/time><strong>杠铃卧推<\/strong><\/div><p>训练起点/)
    assert.match(marked, /07:02:30<\/time><strong>上斜哑铃卧推<\/strong><\/div><p>首组记录/)
    assert.match(marked, /07:02:31<\/time><strong>绳索侧平举<\/strong>/)
    assert.doesNotMatch(marked, /aria-pressed/)
    assert.doesNotMatch(marked, /超出时段/)
    assert.equal((marked.match(/<polyline/g) || []).length, 1)
    assert.doesNotMatch(report, /外加负重|训练量分布/)
    const multi = structuredClone(ready)
    multi.status = 'needs_source'; multi.heart_rate.selected_source = null
    multi.heart_rate.summary.sample_count = 0
    multi.heart_rate.sources.push({ id: 'watch', label: 'Watch', count: 10 })
    const choices = render(multi)
    assert.match(choices, /选择本次佩戴的设备/)
    assert.match(choices, /value="air"/)
    assert.match(choices, /value="watch"/)
    assert.doesNotMatch(choices, /平均心率/)
    assert.doesNotMatch(choices, /class="st-open-health"/)
    const expired = render({ ...waiting, status: 'unavailable', next_attempt_at: null })
    assert.match(expired, /未获取到这段时间的心率/)
    assert.match(expired, /重新获取/)
  } finally { await vite.close() }
})

test('report waits for session save, refreshes late data, pauses when hidden, and ignores stale responses', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/', pretendToBeVisual: true })
  const win = dom.window
  const previous = new Map()
  for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, IS_REACT_ACT_ENVIRONMENT: true })) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key))
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
  }
  const requests = []
  let response = collecting, defer = false, resolveOld
  previous.set('fetch', Object.getOwnPropertyDescriptor(globalThis, 'fetch'))
  globalThis.fetch = async (url, options = {}) => {
    requests.push({ url, options })
    const value = defer ? await new Promise(resolve => { resolveOld = resolve }) : response
    return { ok: true, status: 200, json: async () => value }
  }
  const vite = await makeVite()
  let root
  try {
    const { createRoot } = await import('react-dom/client')
    const { default: WorkoutPhysiology } = await vite.ssrLoadModule('/src/components/WorkoutPhysiology.jsx')
    root = createRoot(win.document.getElementById('root'))
    const render = async (serverSaved = true, visible = true, current = session) => act(async () => root.render(React.createElement(WorkoutPhysiology, { session: current, serverSaved, visible })))
    await render(false)
    assert.equal(requests.length, 0)
    assert.match(win.document.body.textContent, /保存到服务器后/)
    await render()
    assert.equal(requests.length, 1)
    assert.equal(requests[0].url, '/api/strength/sessions/session-1/physiology')
    assert.match(win.document.body.textContent, /正在自动获取训练数据/)
    assert.equal(win.document.querySelector('.st-open-health'), null)
    response = { ...collecting, attempts: 1, status: 'waiting_sync', checked_at: '2026-11-08T12:05:20Z' }
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    assert.equal(win.document.querySelector('.st-open-health'), null)
    response = waiting
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    assert.match(win.document.body.textContent, /等待设备数据同步/)
    assert.ok(win.document.querySelector('.st-open-health'))
    response = ready
    await act(async () => win.document.querySelector('button').click())
    assert.equal(requests.at(-1).options.method, 'POST')
    assert.equal(requests.at(-1).url, '/api/strength/sessions/session-1/physiology/refresh')
    assert.match(win.document.body.textContent, /110.5/)

    // A real user link opens the official URL; returning queues a cloud fetch.
    const appLink = win.document.querySelector('.st-open-health > a')
    appLink.addEventListener('click', event => event.preventDefault()) // JSDOM has no native navigation.
    response = { ...ready, status: 'ready' }
    await act(async () => appLink.click())
    Object.defineProperty(win.document, 'visibilityState', { configurable: true, value: 'hidden' })
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    Object.defineProperty(win.document, 'visibilityState', { configurable: true, value: 'visible' })
    const beforeReturn = requests.length
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    assert.equal(requests.length, beforeReturn + 1)
    assert.equal(requests.at(-1).options.method, 'POST')
    assert.equal(requests.at(-1).url, '/api/strength/sessions/session-1/physiology/refresh')
    assert.equal(win.document.querySelector('.st-open-health'), null)
    defer = true
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    const oldRequest = requests.at(-1)
    Object.defineProperty(win.document, 'visibilityState', { configurable: true, value: 'hidden' })
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    assert.equal(oldRequest.options.signal.aborted, true)
    const count = requests.length
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    assert.equal(requests.length, count)
    defer = false
    Object.defineProperty(win.document, 'visibilityState', { configurable: true, value: 'visible' })
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    await act(async () => resolveOld(waiting))
    assert.match(win.document.body.textContent, /110.5/)
    assert.doesNotMatch(win.document.body.textContent, /等待设备数据同步/)
    await render(true, false)
    const hiddenCount = requests.length
    await act(async () => win.document.dispatchEvent(new win.Event('visibilitychange')))
    assert.equal(requests.length, hiddenCount)
    response = waiting
    await render(true, true, { ...session, id: 'session-2' })
    assert.equal(requests.at(-1).url, '/api/strength/sessions/session-2/physiology')
    assert.doesNotMatch(win.document.body.textContent, /110.5/)
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
