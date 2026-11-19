import test from 'node:test'
import assert from 'node:assert/strict'
import { workoutSnapshot, createWorkoutPublisher, nativeRequest, isNativeHealth, createChromePublisher } from '../src/native/bridge.js'
import { startSession, togglePause, finishSession } from '../src/training/strength.js'

test('native snapshot follows the focused workout and preserves the existing pause/rest timeline', () => {
  const moves = ['下拉', '卧推'].map((name, index) => ({ id: `move${index}`, name, load_mode: 'external' }))
  const session = startSession({ name: '测试', exercises: moves.map(m => ({ exercise_id: m.id, set_count: 4, rest_seconds: 90, unit: 'lb' })) }, moves)
  session.started_at = '2026-11-08T12:00:00Z'
  session.exercises[0].sets[0].completed_at = '2026-11-08T12:05:00Z'
  session.rest_until = '2026-11-08T12:06:30Z'
  session.notes = 'private notes'
  const first = workoutSnapshot(session)
  assert.equal(first.startedAt, Date.parse(session.started_at) / 1000)
  assert.equal(first.completedSets, 1); assert.equal(first.plannedSets, 8)
  assert.equal(first.currentSet, 2)
  const second = workoutSnapshot(session, session.exercises[1].id)
  assert.equal(second.movementName, '卧推'); assert.equal(second.movementIndex, 2)
  const paused = togglePause(session, '2026-11-08T12:05:30Z')
  assert.equal(workoutSnapshot(paused).pausedAt, Date.parse(paused.paused_at) / 1000)
  const resumed = workoutSnapshot(togglePause(paused, '2026-11-08T12:06:30Z'))
  assert.equal(resumed.pausedSeconds, 60)
  assert.equal(resumed.restUntil, first.restUntil + 60)
  assert.equal(workoutSnapshot(finishSession(session)), null)
  assert.equal(workoutSnapshot(null), null)
  assert.doesNotMatch(JSON.stringify(first), /private notes|weight|reps|heart_rate|token/)
})

test('publisher serializes/coalesces edits and always clears after an in-flight update', async () => {
  const calls = []; let release
  const publish = createWorkoutPublisher(async value => {
    calls.push(value)
    if (calls.length === 1) await new Promise(resolve => { release = resolve })
  })
  const done = publish({ completedSets: 0 })
  await Promise.resolve()
  publish({ completedSets: 1 }); publish({ completedSets: 2 }); publish(null)
  assert.equal(calls.length, 1)
  release(); await done
  assert.deepEqual(calls, [{ completedSets: 0 }, null])
  await publish(null)
  assert.equal(calls.length, 2)
  await publish(null, true)
  assert.equal(calls.length, 3)
  await publish({ completedSets: 3 })
  assert.equal(calls.at(-1).completedSets, 3)
})

test('failed bridge sync can retry and a browser/PWA does not invoke native functions', async () => {
  let count = 0
  const publish = createWorkoutPublisher(async () => { if (++count === 1) throw new Error('interrupted') })
  await publish({ completedSets: 1 }); await publish({ completedSets: 1 })
  assert.equal(count, 2)
  assert.equal(isNativeHealth({}), false)
  assert.equal(await nativeRequest('enableRestReminders', {}, {}), null)
  const sent = []
  const native = { __HEALTH_NATIVE__: { version: 1 }, webkit: { messageHandlers: { healthNative: { postMessage: async message => { sent.push(message); return { liveActivitiesEnabled: true } } } } } }
  assert.equal((await nativeRequest('status', {}, native)).liveActivitiesEnabled, true)
  assert.deepEqual(sent, [{ version: 1, type: 'status' }])
})

test('native navigation hides web navigation only after acknowledgement, and a late reply cannot restore signed-in chrome', async () => {
  const classes = new Set(), calls = []
  let release
  const browser = { __HEALTH_NATIVE__: { version: 1, capabilities: ['chrome-v1'] },
    document: { documentElement: { classList: { toggle(name, on) { on ? classes.add(name) : classes.delete(name) } } } },
    webkit: { messageHandlers: { healthNative: { postMessage: async message => {
      calls.push(message)
      if (calls.length === 1) await new Promise(resolve => { release = resolve })
      return { nativeChromeVersion: 1 }
    } } } } }
  const publish = createChromePublisher(browser)
  const pending = publish({ authenticated: true, tab: 'strength' })
  await Promise.resolve()
  assert.equal(classes.has('health-native-chrome'), false)
  publish({ authenticated: false, tab: 'strength' })
  release(); await pending
  assert.equal(classes.has('health-native-chrome'), false)
  await publish({ authenticated: true, tab: 'strength' })
  assert.equal(classes.has('health-native-chrome'), true)
  const before = calls.length
  await publish({ authenticated: true, tab: 'strength' })
  assert.equal(calls.length, before)
})

test('legacy native hosts and rejected navigation handshakes retain the working web controls', async () => {
  let toggles = 0, calls = 0
  const browser = { __HEALTH_NATIVE__: { version: 1 },
    document: { documentElement: { classList: { toggle() { toggles++ } } } },
    webkit: { messageHandlers: { healthNative: { postMessage: async () => { calls++; return {} } } } } }
  await createChromePublisher(browser)({ authenticated: true })
  assert.equal(calls, 0)
  browser.__HEALTH_NATIVE__.capabilities = ['chrome-v1']
  await createChromePublisher(browser)({ authenticated: true })
  assert.equal(calls, 1); assert.equal(toggles, 0)
})
