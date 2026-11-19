import test from 'node:test'
import assert from 'node:assert/strict'
import { hasPendingTraining, clearHealthCache } from '../src/training/privacy.js'

function storage(records) {
  const map = new Map([['health-strength-records-v1',JSON.stringify(records)],
    ['health-strength-catalog-v1','private'],['health-webpush-subscription-v1','id'],['other-app','keep']])
  return { getItem:key=>map.get(key)||null, removeItem:key=>map.delete(key), map }
}

test('logout refuses to erase unsynced or conflicted workouts',()=>{
  for (const record of [{dirty:true},{blocked:{}},{alternative:{}}]) {
    const data=storage({workout:record})
    assert.equal(hasPendingTraining(data),true)
    assert.throws(()=>clearHealthCache(data),/尚未同步/)
    assert.ok(data.map.has('health-strength-records-v1'))
  }
})

test('logout clears synced Health records and push identifier without touching other apps',()=>{
  const data=storage({workout:{dirty:false}})
  assert.equal(hasPendingTraining(data),false)
  clearHealthCache(data)
  assert.deepEqual([...data.map.entries()],[['other-app','keep']])
})

test('unreadable training cache is preserved instead of silently discarded',()=>{
  const data=storage({});data.map.set('health-strength-records-v1','broken')
  assert.equal(hasPendingTraining(data),true)
  assert.throws(()=>clearHealthCache(data),/尚未同步/)
})
