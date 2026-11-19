import { rememberTrainingPlan } from '../training/planCache'
const API_BASE = '/api'

export const getHome = signal => request('/home', { signal }).then(rememberTrainingPlan)
export const getHomeBrief = signal => request('/home/brief', { signal })
export const requestHomeBrief = (signal, force=false) => request(`/home/brief${force?'?force=true':''}`, { method: 'POST', signal })
export const refreshHome = signal => timedRequest('/home/refresh', { method: 'POST', signal }, 85000).then(rememberTrainingPlan)
export const saveHomeGoals = value => request('/home/goals', { method: 'PUT', body: JSON.stringify(value) })
export const saveHomeStepGoal = value => request('/home/step-goal', { method: 'PUT', body: JSON.stringify(value) })
export const saveHomeFeedback = value => request('/home/feedback', { method: 'PUT', body: JSON.stringify(value) })
export const saveHomeWalk = value => request('/home/walk', { method: 'PUT', body: JSON.stringify(value) })
export const linkHomePlan = value => request('/home/plan/link', { method: 'PUT', body: JSON.stringify(value) }).then(rememberTrainingPlan)
export const nextHomeRound = () => request('/home/plan/next', { method: 'POST' }).then(rememberTrainingPlan)

export const getWebPushConfig = () => request('/webpush/config')
export const getWebPushSubscription = id => request(`/webpush/subscription?id=${id}`)
export const saveWebPushSubscription = value => request('/webpush/subscriptions', { method: 'POST', body: JSON.stringify(value) })
export const removeWebPushSubscription = id => request('/webpush/subscriptions', { method: 'DELETE', body: JSON.stringify({ id }) })

async function handleResponse(res) {
  if (res.status === 401) {
    window.dispatchEvent(new Event('unauthorized'))
  }
  if (!res.ok) {
    let message = `请求未完成（${res.status}）`
    let deleted
    try {
      const body = await res.json()
      deleted = body.detail?.deleted
      if (typeof body.detail === 'string') message = body.detail
      else if (body.detail?.message) message = body.detail.message
      else if (Array.isArray(body.detail)) message = body.detail.slice(0, 3).map(e => e.msg).join('；')
    } catch (_) {
      // Keep the status-based message for non-JSON errors.
    }
    const error = new Error(message)
    error.status = res.status
    if (deleted) error.deleted = deleted
    throw error
  }
  return res.json()
}

async function request(url, options = {}) {
  const res = await fetch(`${API_BASE}${url}`, {
    credentials: 'same-origin',
    ...options,
    headers: {
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...(options.headers || {}),
    },
  })
  return handleResponse(res)
}

async function timedRequest(url, options = {}, timeoutMs = 15000) {
  const controller = new AbortController()
  const abort = () => controller.abort()
  if (options.signal?.aborted) abort()
  else options.signal?.addEventListener('abort', abort, { once: true })
  let timer
  const timeoutError = new Error('请求超时，请稍后重试。')
  timeoutError.code = 'request_timeout'
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => { controller.abort(); reject(timeoutError) }, timeoutMs)
  })
  try { return await Promise.race([request(url, { ...options, signal: controller.signal }), deadline]) }
  finally {
    clearTimeout(timer)
    options.signal?.removeEventListener('abort', abort)
  }
}

export function loginApp(username, password) {
  return request('/auth/app-login', {
    method: 'POST',
    body: JSON.stringify({ username, password }),
  })
}

export function getAppAuthStatus() {
  return request('/auth/app-status')
}

export function getIntegrationStatus() {
  return request('/integrations/status')
}

export function sendTelegramTest() {
  return request('/integrations/telegram/test', { method: 'POST' })
}

export function logoutApp() {
  return request('/auth/logout', { method: 'POST' })
}

export function getHealthToday(metric, signal) {
  return metric
    ? timedRequest(`/health/today?metric=${encodeURIComponent(metric)}`, { signal })
    : request('/health/today')
}

export function getAuthStatus() {
  return request('/auth/status')
}

export function getHealthHistory(days = 14, signal) {
  const url = `/health/history?days=${days}`
  return signal ? timedRequest(url, { signal }, days <= 8 ? 15000 : 45000) : request(url)
}

export function getRecentWorkouts(limit = 10) {
  return request(`/workouts/recent?limit=${limit}`)
}

export function getWorkoutArchive(signal) {
  return request('/workouts/archive', { signal })
}

export function getTrainingArchive(days, signal) {
  return request(`/workouts/training/archive${days ? `?days=${days}` : ''}`, { signal })
}

export function getWorkoutStats() {
  return request('/workouts/stats')
}

export function getTodayInsights(signal) {
  return request('/insights/today', { signal })
}

export function getObservationArchive(signal) {
  return request('/insights/archive', { signal })
}

export function getInsightsHistory(days = 7) {
  return request(`/insights/history?days=${days}`)
}

export function triggerInsight(slot) {
  return request(`/insights/generate/${slot}`, { method: 'POST' })
}

export function getSleepHistory(days = 14, signal) {
  return request(`/health/sleep?days=${days}`, { signal })
}

export function getWeeklyObservation(signal) {
  return request('/insights/weekly', { signal })
}

export function triggerWeeklyObservation() {
  return request('/insights/weekly/generate', { method: 'POST' })
}

export const getStrengthCatalog = () => request('/strength/catalog')
export const getExerciseProgress = (id, signal) => timedRequest(`/strength/exercises/${encodeURIComponent(id)}/history`, { signal }, 20000)
export const createStrengthExercise = (exercise) => request('/strength/exercises', {
  method: 'POST', body: JSON.stringify(exercise),
})
export const saveStrengthTemplate = (template, expected_version) => request(`/strength/templates/${template.id}`, {
  method: 'PUT', body: JSON.stringify({ template, expected_version }),
})
export const getStrengthSessions = () => request('/strength/sessions')
export const getStrengthDeletions = () => request('/strength/session-deletions')
export async function deleteStrengthSession(id, version) {
  try {
    return await timedRequest(`/strength/sessions/${id}/delete`, { method: 'POST', body: JSON.stringify({ expected_version: version }) }, 12000)
  } catch (error) {
    error.uncertain = !error.status || error.status >= 500
    throw error
  }
}
export const getStrengthSession = (id, timeoutMs = 15000) => timedRequest(`/strength/sessions/${id}`, {}, timeoutMs)
export const getSessionReview = (id, signal) => timedRequest(`/strength/sessions/${id}/review`, { signal })
export const generateSessionReview = (id, signal) => timedRequest(`/strength/sessions/${id}/review`, { method: 'POST', signal })
export const getWorkoutPhysiology = (id, signal) => request(`/strength/sessions/${id}/physiology`, { signal })
export const refreshWorkoutPhysiology = (id, signal) => request(`/strength/sessions/${id}/physiology/refresh`, { method: 'POST', signal })
export const selectWorkoutHeartSource = (id, source_id, signal) => request(`/strength/sessions/${id}/physiology/source`, {
  method: 'PUT', body: JSON.stringify({ source_id }), signal,
})
export async function saveStrengthSession(session, expected_version) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 15000)
  try {
    return await request(`/strength/sessions/${session.id}`, {
      method: 'PUT', body: JSON.stringify({ session, expected_version }), signal: controller.signal,
    })
  } finally { clearTimeout(timer) }
}
