import { PLAN_CACHE_KEY, clearTrainingPlan } from './planCache.js'
const KEYS = ['health-strength-records-v1', 'health-strength-catalog-v1', PLAN_CACHE_KEY,
  'health-strength-deletions-v1', 'health-strength-imported-v1', 'health-webpush-subscription-v1', 'health-set-options-used']

export function hasPendingTraining(storage = globalThis.localStorage) {
  if (!storage) return false
  try {
    const records = JSON.parse(storage.getItem(KEYS[0]) || '{}')
    return Object.values(records).some(record => record.dirty || record.blocked || record.alternative)
  } catch { return true }
}

export function clearHealthCache(storage = globalThis.localStorage) {
  if (!storage) return
  if (hasPendingTraining(storage)) throw new Error('训练尚未同步，请联网完成同步后再退出。')
  clearTrainingPlan()
  KEYS.forEach(key => storage.removeItem(key))
  for(let i=storage.length-1;i>=0;i--){const key=storage.key(i);if(key?.startsWith('health-progress-view-'))storage.removeItem(key)}
}
