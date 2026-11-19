import test from 'node:test'
import assert from 'node:assert/strict'
import {ageText,recordClock,freshnessSummary} from '../src/dataFreshness.js'
const now=Date.parse('2026-11-17T05:05:00Z'),zone='America/New_York'
test('freshness comes from observed activity timestamps even after a newer app read',()=>{
 const data={checked_at:'2026-11-17T05:05:00Z',records:{steps:{observed_at:'2026-11-17T04:53:00Z'},activity:{observed_at:'2026-11-17T04:57:00Z'}}}
 const status=freshnessSummary(data,zone,now)
 assert.equal(status.at,'2026-11-17T04:57:00Z')
 assert.equal(status.label,'活动记录 昨23:57 · 8分钟前')
 assert.equal(freshnessSummary({checked_at:data.checked_at},zone,now),null)
})
test('age handles empty, future, midnight and prolonged gaps without claiming a sync delay',()=>{
 assert.equal(ageText('2026-11-17T05:04:40Z',now),'刚刚')
 assert.equal(ageText('2026-11-17T04:00:00Z',now),'1小时前')
 assert.equal(ageText(null,now),null)
 assert.equal(ageText('2026-11-17T05:06:00Z',now),null)
 assert.equal(recordClock('2026-11-17T04:57:00Z',zone,now),'昨23:57')
})
test('device sync is a separate fallback and cannot replace a measured record timestamp',()=>{
 const device={last_sync_at:'2026-11-17T05:00:00Z',device_name:'Fitbit Air'}
 assert.equal(freshnessSummary({device},zone,now).kind,'device')
 assert.equal(freshnessSummary({device,records:{activity:{observed_at:'2026-11-17T04:57:00Z'}}},zone,now).kind,'record')
})
