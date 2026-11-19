import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs/promises'
import vm from 'node:vm'
import React, { act } from 'react'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'

const id = 'b3336910-eeee-4516-bba3-c4c824e785b1'
test('service worker displays workout and observation notifications and opens only local pages', async () => {
  const handlers = {}, displayed = [], opened = []
  const self = { addEventListener: (name, callback) => { handlers[name] = callback }, location: { origin: 'https://health.frankandpatrick.com' }, skipWaiting() {},
    registration: { showNotification: async (title, options) => displayed.push({ title, options }) },
    clients: { claim: async () => {}, matchAll: async () => [], openWindow: async url => opened.push(url) },
  }
  const source = await fs.readFile(new URL('../public/push-sw.js', import.meta.url), 'utf8')
  vm.runInNewContext(source, { self, URL })
  let work
  handlers.push({ data: { json: () => ({ session_id: id, body: 'untrusted data is not displayed' }) }, waitUntil: promise => { work = promise } })
  await work
  assert.equal(displayed.length, 1)
  assert.equal(displayed[0].options.data.path, `/?workout=${id}#strength`)
  assert.doesNotMatch(displayed[0].options.body, /untrusted/)
  handlers.notificationclick({ notification: { close() {}, data: displayed[0].options.data }, waitUntil: promise => { work = promise } })
  await work
  assert.equal(opened[0], `https://health.frankandpatrick.com/?workout=${id}#strength`)
  handlers.push({ data: { json: () => ({ kind: 'observation', slot: 'evening', id: 12, body: 'health data' }) },
    waitUntil: promise => { work = promise } })
  await work
  assert.equal(displayed[1].title, 'Health · 晚间健康分析已生成')
  assert.equal(displayed[1].options.tag, 'observation-12')
  assert.doesNotMatch(displayed[1].options.body, /health data/)
  handlers.notificationclick({ notification: { close() {}, data: displayed[1].options.data }, waitUntil: promise => { work = promise } })
  await work
  assert.equal(opened.at(-1), 'https://health.frankandpatrick.com/?observation=evening#dashboard')
  handlers.notificationclick({ notification: { close() {}, data: { path: 'https://evil.test/' } }, waitUntil: promise => { work = promise } })
  await work
  assert.equal(opened.at(-1), 'https://health.frankandpatrick.com/#strength')
  assert.equal(handlers.fetch, undefined)
})

test('permission is requested only by a tap, then subscription is saved and can be disabled', async () => {
  const dom = new JSDOM('<div id="root"></div>', { url: 'https://health.frankandpatrick.com/', pretendToBeVisual: true })
  const win = dom.window, previous = new Map(), calls = []
  const set = (key, value) => { previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key)); Object.defineProperty(globalThis, key, { configurable: true, writable: true, value }) }
  const notification = { permission: 'default', requestPermission: async () => { calls.push('permission'); notification.permission = 'granted'; return 'granted' } }
  Object.defineProperty(win, 'isSecureContext', { value: true })
  win.Notification = notification; win.PushManager = function () {}
  let subscribed = null, configResolve
  const subscription = { toJSON: () => ({ endpoint: 'https://web.push.apple.com/test12345', keys: { p256dh: 'test', auth: 'test' } }), unsubscribe: async () => { subscribed = null; return true } }
  const registration = { showNotification: async title => calls.push(title),
    pushManager: { getSubscription: async () => subscribed, subscribe: async value => { assert.equal(value.userVisibleOnly, true); subscribed = subscription; return subscription } } }
  Object.defineProperty(win.navigator, 'serviceWorker', { value: { register: async path => { calls.push(`register:${path}`); return registration }, ready: Promise.resolve(registration) } })
  for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, localStorage: win.localStorage, Notification: notification, IS_REACT_ACT_ENVIRONMENT: true })) set(key, value)
  set('fetch', async (url, options = {}) => {
    calls.push(`${options.method || 'GET'}:${url}`)
    if (url === '/api/webpush/config') await new Promise(resolve => { configResolve = resolve })
    return { ok: true, status: 200, json: async () => url === '/api/webpush/config' ? { public_key: Buffer.alloc(65, 1).toString('base64url') } : { id: 'a'.repeat(64), active: options.method !== 'DELETE' } }
  })
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })
  let root
  try {
    const { createRoot } = await import('react-dom/client')
    const { default: WebPushControl } = await vite.ssrLoadModule('/src/components/WebPushControl.jsx')
    root = createRoot(win.document.getElementById('root'))
    await act(async () => root.render(React.createElement(WebPushControl)))
    assert.equal(calls.includes('permission'), false)
    assert.equal(win.document.querySelector('button').textContent, '开启通知')
    await act(async () => win.document.querySelector('button').click())
    assert.ok(calls.includes('permission'))
    assert.equal(calls.some(value => value.startsWith('POST:')), false)
    await act(async () => configResolve())
    assert.equal(win.document.querySelector('button').textContent, '关闭通知')
    assert.ok(calls.includes('POST:/api/webpush/subscriptions'))
    assert.equal(localStorage.getItem('health-webpush-subscription-v1'), 'a'.repeat(64))
    const testButton = [...win.document.querySelectorAll('button')].find(button => button.textContent === '测试本机通知')
    assert.ok(testButton)
    await act(async () => testButton.click())
    assert.ok(calls.includes('训练报告通知测试'))
    assert.equal(calls.filter(call => call === 'permission').length, 1)
    await act(async () => win.document.querySelector('button').click())
    assert.ok(calls.includes('DELETE:/api/webpush/subscriptions'))
    assert.equal(subscribed, null)
    assert.equal(localStorage.getItem('health-webpush-subscription-v1'), null)
  } finally {
    if (root) await act(async () => root.unmount())
    await vite.close(); dom.window.close()
    for (const [key, descriptor] of previous) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key] }
  }
})
