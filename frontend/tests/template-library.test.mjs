import test from 'node:test'
import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import React, { act } from 'react'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'
import { groupTemplates, filterTemplates, durationLabel } from '../src/training/templateLibrary.js'

const exercises = JSON.parse(await readFile(new URL('../../backend/app/data/exercises.json', import.meta.url)))
const programs = JSON.parse(await readFile(new URL('../../backend/app/data/programs.json', import.meta.url)))
const posture = JSON.parse(await readFile(new URL('../../backend/app/data/posture_programs.json', import.meta.url)))
const other = { id: 'custom-back', name: '我的背部训练', exercises: [{ exercise_id: 'wide-grip-pulldown', set_count: 3 }] }
const records = [...programs, ...posture, other].map(template => ({ template, version: 1 }))

test('round groups preserve every template and pair company with home without changing data', () => {
  const before = JSON.stringify(records)
  const grouped = groupTemplates(records)
  assert.deepEqual(grouped.flatMap(group => group.records.map(row => row.template.id)).sort(), records.map(row => row.template.id).sort())
  for (const group of grouped.filter(group => group.round != null)) {
    assert.equal(group.records.length, 2)
    assert.match(group.locations, /公司.*居家/)
  }
  assert.equal(grouped[0].id, 'posture')
  assert.equal(grouped[0].records.length, 2)
  assert.equal(grouped.find(group => group.id === 'weekend').records.length, 2)
  assert.ok(grouped.find(group => group.id === 'other').records.some(row => row.template.id === other.id))
  assert.equal(JSON.stringify(records), before)
})

test('search combines scenario with exercise and muscle names, handles whitespace and empty matches', () => {
  assert.equal(filterTemplates(records, exercises, { category: 'company' }).length, 4)
  assert.equal(filterTemplates(records, exercises, { category: 'home' }).length, 4)
  assert.equal(filterTemplates(records, exercises, { category: 'weekend' }).length, 2)
  assert.deepEqual(filterTemplates(records, exercises, { query: 'A' }).map(row => row.template.id).sort(), ['guided-upper-a','personal-home-a'].sort())
  assert.deepEqual(filterTemplates(records, exercises, { query: '  我的 背部 ' }).map(row => row.template.id), [other.id])
  assert.ok(filterTemplates(records, exercises, { query: '宽距高位下拉' }).some(row => row.template.id === other.id))
  assert.ok(filterTemplates(records, exercises, { query: '背部', category: 'company' }).length)
  assert.equal(filterTemplates(records, exercises, { query: '不存在的模板' }).length, 0)
  assert.equal(durationLabel({}), null)
  assert.equal(durationLabel({ duration_min: 20, duration_max: 30 }), '20–30 分钟')
  assert.equal(durationLabel({ duration_min: 25, duration_max: 25 }), '25 分钟')
})

test('library groups, filters, previews, edits and starts the original records; active workouts disable starting', async () => {
  const dom = new JSDOM('<div id="root"></div>', { pretendToBeVisual: true, url: 'http://localhost/' })
  const previous = new Map(), win = dom.window
  for (const [key, value] of Object.entries({ window: win, document: win.document, navigator: win.navigator, HTMLElement: win.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true })) {
    previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key)); Object.defineProperty(globalThis, key, { value, configurable: true, writable: true })
  }
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })
  let root
  try {
    const { createRoot } = await import('react-dom/client')
    const { default: TemplateLibrary } = await vite.ssrLoadModule('/src/components/TemplateLibrary.jsx')
    const preview = [], edits = [], starts = []
    const props = { templates: records, exercises, routine: { record: records[0] }, onPreview: value => preview.push(value), onEdit: value => edits.push(value), onStart: value => starts.push(value) }
    root = createRoot(document.getElementById('root'))
    await act(async () => root.render(React.createElement(TemplateLibrary, props)))
    assert.equal(document.querySelectorAll('.st-template-group').length, 7)
    assert.equal(document.querySelectorAll('.st-template-group[open]').length, 0)
    assert.equal(document.querySelectorAll('.st-template-card').length, records.length)
    assert.equal(starts.length, 0)
    const click = async node => { assert.ok(node); await act(async () => node.click()) }
    assert.equal(document.querySelector('.st-template-filters'), null)
    assert.equal(document.querySelector('[aria-label="搜索训练模板"]'), null)
    assert.equal(document.querySelector('.st-template-result-meta'), null)
    const row = document.querySelector('[data-template-id="custom-back"]')
    row.closest('details').open = true
    await click(row.querySelector('.st-template-preview')); assert.equal(preview.at(-1), other)
    await click(row.querySelector('.st-template-edit')); assert.equal(edits.at(-1), records.at(-1))
    await click(row.querySelector('.st-primary')); assert.equal(starts.at(-1), other)
    await act(async () => root.render(React.createElement(TemplateLibrary, { ...props, disabled: true })))
    assert.ok([...document.querySelectorAll('.st-template-card .st-primary')].every(button => button.disabled))
  } finally {
    if (root) await act(async () => root.unmount())
    await vite.close(); dom.window.close()
    for (const [key, descriptor] of previous) { if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete globalThis[key] }
  }
})
