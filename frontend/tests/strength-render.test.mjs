import test from 'node:test'
import assert from 'node:assert/strict'
import React from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { createServer } from 'vite'
import { STORE_KEY, CATALOG_KEY, startSession } from '../src/training/strength.js'

test('render templates and a restored in-progress workout through real React components', async () => {
  const exercises = [
    { id: 'wide-grip-pulldown', name: '宽距高位下拉', muscles: ['背部'], equipment: '高位下拉器', load_mode: 'external' },
    { id: 'assisted-dip', name: '双杠臂屈伸（辅助）', muscles: ['胸部'], equipment: '辅助双杠器', load_mode: 'assistance' },
  ]
  const template = { id: 'back', name: '背·三角肌后束·二头', exercises: [{ exercise_id: exercises[0].id, set_count: 4, rest_seconds: 90, unit: 'lb' }] }
  const catalog = { exercises, templates: [{ template, version: 1 }] }
  const cache = { [CATALOG_KEY]: JSON.stringify(catalog) }
  globalThis.localStorage = { getItem: key => cache[key] || null }
  const vite = await createServer({ server: { middlewareMode: true, hmr: false, ws: false }, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] } })
  try {
    const { default: StrengthTraining } = await vite.ssrLoadModule('/src/components/StrengthTraining.jsx')
    const { default: HealthShell } = await vite.ssrLoadModule('/src/components/HealthShell.jsx')
    const renderPage = () => renderToStaticMarkup(React.createElement(HealthShell, {
      activeTab: 'strength', setActiveTab() {}, authed: true,
    }, React.createElement(StrengthTraining, { active: true })))
    const home = renderPage()
    assert.match(home, /健康与训练/)
    assert.match(home, /自由训练/)
    assert.match(home, /背·三角肌后束·二头/)
    assert.match(home, /开始训练/)
    assert.match(home, /查看背·三角肌后束·二头的动作/)
    assert.doesNotMatch(home, /st-template-moves/)
    const session = startSession(template, exercises)
    session.exercises.push({ ...structuredClone(session.exercises[0]), id: crypto.randomUUID(), exercise_id: exercises[1].id, name: exercises[1].name, load_mode: 'assistance', equipment: exercises[1].equipment })
    cache[STORE_KEY] = JSON.stringify({ [session.id]: { session, version: 1, dirty: false } })
    const restored = renderPage()
    assert.match(restored, /正在进行的训练/)
    assert.match(restored, /宽距高位下拉第1组重量 磅/)
    assert.match(restored, /已保存到服务器/)
    assert.match(restored, /切换动作/)
    assert.match(restored, /下一个动作/)
    assert.doesNotMatch(restored, /双杠臂屈伸（辅助）第1组辅助重量/)
    assert.equal((restored.match(/st-exercise-card open/g) || []).length, 1)
    assert.match(restored, /aria-pressed="false"/)
    assert.doesNotMatch(restored, /lb·次|kg·次/)
    session.exercises[0].sets.forEach(row => { row.weight = 100; row.reps = 8; row.completed_at = 'recorded' })
    session.rest_until = new Date(Date.now() + 90000).toISOString()
    cache[STORE_KEY] = JSON.stringify({ [session.id]: { session, version: 1, dirty: false } })
    const continued = renderPage()
    assert.match(continued, /双杠臂屈伸（辅助）第1组辅助重量 磅/)
    assert.doesNotMatch(continued, /宽距高位下拉第1组重量 磅/)
    assert.match(continued, /组间休息/)
    assert.doesNotMatch(continued, /st-rest-timer/)
    session.exercises.forEach(m => m.sets.forEach(row => { row.completed_at = null }))
    session.rest_until = null
    const hiddenWorkout = renderToStaticMarkup(React.createElement(StrengthTraining, { active: false }))
    assert.doesNotMatch(hiddenWorkout, /st-live-view/)
    assert.match(restored, /新增一组/)
    assert.doesNotMatch(restored, /应用到后续/)
    assert.match(restored, /type="text" inputMode="decimal"/)
    assert.match(restored, /type="text" inputMode="numeric"/)
    assert.doesNotMatch(restored, /自由训练/)
    const { default: TrainingReport } = await vite.ssrLoadModule('/src/components/TrainingReport.jsx')
    session.status = 'completed'; session.ended_at = new Date().toISOString()
    const emptyReport = renderToStaticMarkup(React.createElement(TrainingReport, { session, history: [], savedText: '已保存', canRepeat: true }))
    assert.match(emptyReport, /训练报告/)
    assert.match(emptyReport, /本次没有完成组次/)
    assert.doesNotMatch(emptyReport, /<input/)
    session.timezone = 'Pacific/Kiritimati'
    session.exercises[0].sets[0].weight = 100
    session.exercises[0].sets[0].reps = 9
    session.exercises[0].sets[0].completed_at = session.ended_at
    const old = structuredClone(session)
    old.id = 'imported-history'; old.started_at = '2026-11-01'; old.ended_at = null
    old.exercises[0].sets[0].reps = 8
    Object.assign(session.exercises[0].sets[1], { weight: 110, reps: 3, warmup: true, completed_at: session.ended_at })
    const report = renderToStaticMarkup(React.createElement(TrainingReport, { session, history: [{ session: old }], catalog: exercises, savedText: '已保存', canRepeat: true }))
    assert.match(report, /训练已结束/)
    assert.match(report, /完成组数/)
    assert.match(report, /总次数/)
    assert.match(report, /工作组<\/dt><dd>1/)
    assert.match(report, /热身 1 组/)
    assert.doesNotMatch(report, /外加负重|训练量分布|lb·次|kg·次/)
    assert.match(report, /11月1日/)
    assert.match(report, /同重量/)
    assert.match(report, /100 磅 × 9<\/b> · 最重工作组/)
    assert.doesNotMatch(report, /较上次 \+1 次/) // Partial plans do not claim a comparable gain.
    assert.match(report, /本次复盘/)
    assert.match(report, /点开查看依据与组次/)
    assert.doesNotMatch(report, /首个动作|st-report-highlight/)
    assert.match(report, /训练部位<\/strong> <span>背部/)
    assert.match(report, /动作<\/dt><dd>1/)
    assert.match(report,/动作表现/);assert.doesNotMatch(report,/心率与活动|等待设备数据同步/)
    assert.doesNotMatch(report, /<input/)
    old.exercises[0].sets[0].warmup = true
    const workReport = renderToStaticMarkup(React.createElement(TrainingReport, { session, history: [{ session: old }], savedText: '已保存', canRepeat: true }))
    assert.match(workReport, /暂无可比的历史工作组/)
    assert.match(workReport, /本次复盘/)
    assert.doesNotMatch(workReport, /首个动作/)
    assert.doesNotMatch(workReport, /本次亮点|多做/)
    assert.doesNotMatch(workReport, /本次仅记录了热身组/)
  } finally {
    await vite.close()
    delete globalThis.localStorage
  }
})
