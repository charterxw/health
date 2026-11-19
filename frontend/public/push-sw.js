/* Push delivery only: authenticated pages and API data are never cached here. */
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()))
self.addEventListener('push', event => {
  let message = {}
  try { message = event.data?.json() ?? {} } catch (_) { /* Always display a visible notification. */ }
  if (message.kind === 'observation') {
    const labels = { morning: '早间睡眠分析', evening: '晚间健康分析', weekly: '每周观察' }
    const slot = typeof message.slot === 'string' && Object.hasOwn(labels, message.slot) ? message.slot : null
    const id = Number.isSafeInteger(message.id) && message.id > 0 ? message.id : null
    const path = slot ? `/?observation=${slot}#dashboard` : '/#dashboard'
    event.waitUntil(self.registration.showNotification(`Health · ${slot ? labels[slot] : '今日观察'}已生成`, {
      body: '点此打开首页查看分析。',
      tag: id ? `observation-${id}` : 'health-observation',
      data: { path },
    }))
    return
  }
  const id = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(message.session_id || '') ? message.session_id : null
  const path = id ? `/?workout=${encodeURIComponent(id)}#strength` : '/#strength'
  event.waitUntil(self.registration.showNotification('Health · 训练报告已更新', {
    body: '训练时段的心率数据已获取，点此查看报告。',
    tag: id ? `workout-${id}` : 'health-workout',
    data: { path },
  }))
})
self.addEventListener('notificationclick', event => {
  event.notification.close()
  const candidate = new URL(event.notification.data?.path || '/#strength', self.location.origin)
  const url = candidate.origin === self.location.origin ? candidate.href : `${self.location.origin}/#strength`
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const client of windows) {
      if (new URL(client.url).origin !== self.location.origin) continue
      try {
        const target = await client.navigate(url)
        return await (target || client).focus()
      } catch (_) { /* Fall through to opening the app. */ }
    }
    return self.clients.openWindow(url)
  })())
})
