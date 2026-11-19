import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import React, { act } from 'react'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'
import { startSession, newSet } from '../src/training/strength.js'

test('simple template library preserves previews; enabling progression starts a persisted, unchecked target', async () => {
  const exercises = JSON.parse(await readFile(new URL('../../backend/app/data/exercises.json', import.meta.url), 'utf8'))
  const programs = JSON.parse(await readFile(new URL('../../backend/app/data/programs.json', import.meta.url), 'utf8'))
  const template = { id: 'back', name: '背部训练', exercises: [{ exercise_id: 'wide-grip-pulldown', set_count: 4, rest_seconds: 90, unit: 'lb' }] }
  const old = startSession(template, exercises)
  old.status = 'completed'; old.started_at = '2026-11-10T16:00:00Z'; old.ended_at = '2026-11-10T16:30:00Z'
  old.exercises[0].sets = [newSet({ weight: 50, reps: 5, warmup: true, completed_at: old.ended_at }),
    ...Array.from({ length: 3 }, () => newSet({ weight: 100, reps: 12, completed_at: old.ended_at }))]
  const records = [{ session: old, version: 1 }], writes = [], globals = new Map()
  const dom = new JSDOM('<div id="root"></div>', { url: 'http://localhost/#strength', pretendToBeVisual: true })
  const win = dom.window
  win.scrollTo = () => {}; win.HTMLElement.prototype.scrollTo = function () {}
  const ok = value => ({ ok: true, status: 200, json: async () => value })
  function set(key, value) {
    globals.set(key, Object.getOwnPropertyDescriptor(globalThis, key))
    Object.defineProperty(globalThis, key, { configurable: true, writable: true, value })
  }
  for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator,
    localStorage: win.localStorage, HTMLElement: win.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true })) set(key, value)
  set('fetch', async (url, options = {}) => {
    if (url === '/api/strength/catalog') return ok({ exercises, templates: [{ template, version: 1 }, ...programs.map(template => ({ template, version: 1 }))] })
    if (url === '/api/strength/sessions') return ok(records)
    if (/\/api\/strength\/exercises\/.+\/history/.test(url)) return ok({ records })
    if (url === '/api/strength/session-deletions' || url.startsWith('/api/workouts/training')) return ok([])
    if (url.startsWith('/api/strength/templates/') && options.method === 'PUT') {
      const body = JSON.parse(options.body); writes.push(body)
      return ok({ template: body.template, version: body.expected_version + 1 })
    }
    if (options.method === 'PUT') { const body = JSON.parse(options.body); return ok({ session: body.session, version: body.expected_version + 1 }) }
    throw new Error(`Unexpected request ${url}`)
  })
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })
  let root
  try {
    const { createRoot } = await import('react-dom/client')
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    root = createRoot(win.document.getElementById('root'))
    await act(async () => root.render(React.createElement(StrengthTraining, { active: true })))
    const click = async node => { assert.ok(node); await act(async () => node.click()) }
    const button = label => [...win.document.querySelectorAll('button')].find(n => n.textContent.trim() === label)
    assert.equal(win.document.querySelector('.st-routine'), null)
    const nextGroup = win.document.querySelector('[data-template-group="round-0"]')
    assert.equal(nextGroup.querySelector('.st-template-next'),null) // No separate recommendation without the shared round source.
    assert.equal(win.document.querySelector('.st-plan-details summary').textContent, '训练说明')
    assert.equal(win.document.querySelector('.st-plan-details').open, false)
    assert.match(win.document.querySelector('.st-plan-details').textContent, /每轮|一轮共72/)
    assert.match(win.document.querySelector('.st-plan-details').textContent, /Y Raise|Y字举/)
    await click(nextGroup.querySelector('summary'))
    await click(nextGroup.querySelector('.st-template-preview'))
    assert.match(win.document.querySelector('[role="dialog"]').textContent, /9 个工作组 \+ 4 个热身组/)
    await click(win.document.querySelector('[aria-label="关闭"]'))
    assert.equal(win.document.querySelector('[role="tab"]'), null)
    await click(win.document.querySelector('[aria-label="查看背部训练的动作"]'))
    assert.match(win.document.querySelector('[role="dialog"]').textContent, /105 磅 · 3 组 × 8 次/)
    await click(win.document.querySelector('[aria-label="关闭"]'))
    await click(win.document.querySelector('[aria-label="编辑背部训练"]'))
    await click(win.document.querySelector('[aria-label="1号动作启用进阶"]'))
    assert.match(win.document.querySelector('[role="dialog"]').textContent, /次数下限/)
    await act(async () => win.document.querySelector('.st-template-form').dispatchEvent(new win.Event('submit', { bubbles: true, cancelable: true })))
    assert.equal(writes.length, 1); assert.equal(writes[0].template.exercises[0].progression, 'double')
    await click([...win.document.querySelectorAll('.st-template-card')].find(n => n.querySelector('h3').textContent === '背部训练').querySelector('.st-template-launch .st-primary'))
    assert.match(win.document.querySelector('.st-prescription').textContent, /105 磅/)
    assert.equal(win.document.querySelector('[aria-label="宽距高位下拉第1组重量 磅"]').value, '50')
    const weightInput = win.document.querySelector('[aria-label="宽距高位下拉第2组重量 磅"]')
    assert.equal(weightInput.value, '105')
    assert.equal(win.document.querySelector('[aria-label="完成宽距高位下拉第1组"]').getAttribute('aria-pressed'), 'false')
    assert.match(win.document.querySelector('.st-prescription').textContent, /全部 3 个工作组达到 12 次/)
  } finally {
    if (root) await act(async () => root.unmount())
    await vite.close(); dom.window.close()
    for (const [key, descriptor] of globals) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor)
      else delete globalThis[key]
    }
  }
})
