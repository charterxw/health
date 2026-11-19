// The native host only accepts messages from the trusted site's main frame.
// Nothing in the browser/PWA depends on this bridge being present.
export function isNativeHealth(browser = globalThis.window) {
  return Boolean(browser?.__HEALTH_NATIVE__?.version === 1
    && browser?.webkit?.messageHandlers?.healthNative?.postMessage)
}

export function hasNativeCapability(name, browser = globalThis.window) {
  return isNativeHealth(browser) && Boolean(browser.__HEALTH_NATIVE__.capabilities?.includes(name))
}

export async function nativeRequest(type, values = {}, browser = globalThis.window) {
  if (!isNativeHealth(browser)) return null
  let timer
  try {
    return await Promise.race([
      browser.webkit.messageHandlers.healthNative.postMessage({ version: 1, type, ...values }),
      // A person may need time to read and answer the system permission prompt.
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('原生功能暂未响应，请重试。')), ['enableRestReminders', 'presentMenu', 'presentConfirmation'].includes(type) ? 120000 : 5000) }),
    ])
  } finally { clearTimeout(timer) }
}

const seconds = value => value ? new Date(value).getTime() / 1000 : null
export function workoutSnapshot(session, focusedID = null) {
  if (!session || session.status !== 'active') return null
  const movements = session.exercises
  const index = Math.max(0, movements.findIndex(m => m.id === focusedID))
  const movement = movements.find(m => m.id === focusedID)
    || movements.find(m => m.sets.some(s => !s.completed_at)) || movements[0]
  const actualIndex = movement ? movements.indexOf(movement) : index
  const nextSet = movement?.sets.findIndex(s => !s.completed_at) ?? -1
  return {
    protocolVersion: 1, sessionID: session.id,
    title: session.title.trim().slice(0, 100) || '力量训练',
    startedAt: seconds(session.started_at), pausedAt: seconds(session.paused_at),
    pausedSeconds: session.paused_seconds || 0, restUntil: seconds(session.rest_until),
    movementName: movement?.name.slice(0, 100) || '添加动作',
    movementIndex: movement ? actualIndex + 1 : 0, movementCount: movements.length,
    completedSets: movements.reduce((n, m) => n + m.sets.filter(s => s.completed_at).length, 0),
    plannedSets: movements.reduce((n, m) => n + m.sets.length, 0),
    currentSet: movement ? nextSet < 0 ? movement.sets.length : nextSet + 1 : 0,
    movementSetCount: movement?.sets.length || 0,
  }
}

// Coalesce edits, preserve ordering, and send no per-second timer updates.
// A sign-out/null state always follows any already-running sync.
export function createWorkoutPublisher(send) {
  let queued, running = null, acknowledged
  const drain = async () => {
    while (queued !== undefined) {
      const value = queued; queued = undefined
      if (value.key === acknowledged && !value.force) continue
      try { await send(value.snapshot); acknowledged = value.key }
      catch { acknowledged = undefined } // Foreground return retries the latest state.
    }
  }
  const start = () => {
    if (!running) running = Promise.resolve().then(drain).finally(() => {
      running = null
      // A publish can arrive between drain resolving and this continuation.
      if (queued !== undefined) start()
    })
    return running
  }
  return (snapshot, force = false) => {
    queued = { snapshot, key: JSON.stringify(snapshot), force }
    return start()
  }
}

export const publishNativeWorkout = createWorkoutPublisher(workout => nativeRequest('syncWorkout', { workout }))

export function createChromePublisher(browser = globalThis.window) {
  let latest
  const publish = createWorkoutPublisher(async chrome => {
    const response = await nativeRequest('syncChrome', { chrome }, browser)
    if (response?.nativeChromeVersion === 1 && latest === JSON.stringify(chrome)) {
      browser.document.documentElement.classList.toggle('health-native-chrome', chrome.authenticated)
    }
  })
  return (chrome, force = false) => {
    if (!hasNativeCapability('chrome-v1', browser)) return Promise.resolve()
    latest = JSON.stringify(chrome)
    return publish(chrome, force)
  }
}
let chromePublisher
export function publishNativeChrome(chrome, force = false) {
  chromePublisher ||= createChromePublisher()
  return chromePublisher(chrome, force)
}
