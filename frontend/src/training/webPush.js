import { getWebPushConfig, getWebPushSubscription, saveWebPushSubscription, removeWebPushSubscription } from '../api/client'

const ID_KEY = 'health-webpush-subscription-v1'
let preparation
export function pushSupport() {
  if (typeof window === 'undefined') return false
  return Boolean(window.isSecureContext && 'Notification' in window && 'PushManager' in window && 'serviceWorker' in navigator)
}
export function preparePush() {
  if (!preparation) preparation = Promise.all([
    getWebPushConfig(),
    navigator.serviceWorker.register('/push-sw.js', { scope: '/', updateViaCache: 'none' }).then(() => navigator.serviceWorker.ready),
  ]).catch(error => { preparation = null; throw error })
  return preparation
}
function decode(value) {
  const raw = atob(value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4))
  return Uint8Array.from(raw, c => c.charCodeAt(0))
}
export async function pushStatus() {
  if (!pushSupport()) return 'unsupported'
  if (Notification.permission === 'denied') return 'denied'
  if (Notification.permission !== 'granted') { preparePush().catch(() => {}); return 'off' }
  const [, registration] = await preparePush()
  const subscription = await registration.pushManager.getSubscription()
  const id = localStorage.getItem(ID_KEY)
  if (!subscription || !id) return 'off'
  const result = await getWebPushSubscription(id)
  return result.active ? 'on' : 'off'
}
export async function enablePush() {
  // Must start inside the button gesture, before awaiting registration/network.
  const permission = await Notification.requestPermission()
  if (permission !== 'granted') throw new Error('尚未允许通知。可以在 iPhone 设置中为 Health 开启通知。')
  const [config, registration] = await preparePush()
  const previous = await registration.pushManager.getSubscription()
  if (previous) {
    const oldId = localStorage.getItem(ID_KEY)
    if (oldId) await removeWebPushSubscription(oldId)
    await previous.unsubscribe()
  }
  const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: decode(config.public_key) })
  try {
    const saved = await saveWebPushSubscription(subscription.toJSON())
    localStorage.setItem(ID_KEY, saved.id)
  } catch (error) {
    await subscription.unsubscribe().catch(() => {})
    throw error
  }
}
export async function disablePush() {
  const id = localStorage.getItem(ID_KEY)
  if (id) await removeWebPushSubscription(id)
  const [, registration] = await preparePush()
  const subscription = await registration.pushManager.getSubscription()
  if (subscription) await subscription.unsubscribe()
  localStorage.removeItem(ID_KEY)
}

export async function showTestNotification() {
  const [, registration] = await preparePush()
  await registration.showNotification('训练报告通知测试', {
    body: '这台设备可以显示来自主屏幕版 Health 的通知。',
    tag: 'health-report-notification-test',
  })
}
