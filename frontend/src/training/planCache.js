export const PLAN_CACHE_KEY = 'health-training-plan-v1'
let current = null
export function readTrainingPlan() {
  try {
    const value = current || JSON.parse(localStorage.getItem(PLAN_CACHE_KEY) || 'null')
    const today = new Intl.DateTimeFormat('en-CA', { timeZone: value?.timezone || 'America/New_York', year:'numeric',month:'2-digit',day:'2-digit' }).format(new Date())
    return value?.date === today && value.plan ? value : null
  } catch { return null }
}
export function rememberTrainingPlan(data) {
  if (!data?.plan) return data
  current = { date:data.date, timezone:data.timezone, plan:data.plan, action:data.action,
    days:(data.days || []).map(({date,sets,sessions})=>({date,sets,sessions})) }
  try { localStorage.setItem(PLAN_CACHE_KEY,JSON.stringify(current)) } catch { /* The memory cache remains usable. */ }
  globalThis.window?.dispatchEvent(new window.Event('health-training-plan'))
  return data
}
export function clearTrainingPlan() { current=null }
