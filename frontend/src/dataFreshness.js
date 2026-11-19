const valid = value => value && Number.isFinite(Date.parse(value))
export function ageText(value, now = Date.now()) {
  if (!valid(value) || Date.parse(value) > now) return null
  const minutes = Math.floor((now - Date.parse(value)) / 60000)
  if (minutes < 1) return '刚刚'
  if (minutes < 60) return `${minutes}分钟前`
  if (minutes < 1440) return `${Math.floor(minutes / 60)}小时前`
  return `${Math.floor(minutes / 1440)}天前`
}
function day(value, timezone) {
  const parts = new Intl.DateTimeFormat('en', {timeZone:timezone,year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date(value))
  return ['year','month','day'].map(type=>parts.find(p=>p.type===type).value).join('-')
}
export function recordClock(value, timezone, now = Date.now()) {
  if (!valid(value)) return '—'
  const stamp = day(value, timezone), today = day(now, timezone)
  const prefix = stamp === today ? '' : stamp === day(now-86400000, timezone) ? '昨' : `${stamp.slice(5).replace('-','/')} `
  return prefix + new Date(value).toLocaleTimeString('zh-CN', {timeZone:timezone,hour:'2-digit',minute:'2-digit',hourCycle:'h23'})
}
export function freshnessSummary(data = {}, timezone, now = Date.now()) {
  const records = Object.values(data.records || {}).map(r=>r.observed_at).filter(at=>valid(at)&&Date.parse(at)<=now)
  const observed = records.sort((a,b)=>Date.parse(b)-Date.parse(a))[0]
  const device = data.device?.last_sync_at
  const at = observed || (valid(device)&&Date.parse(device)<=now ? device : null)
  return at ? {at,kind:observed?'record':'device',label:`${observed?'活动记录':'设备同步'} ${recordClock(at,timezone,now)} · ${ageText(at,now)}`} : null
}
