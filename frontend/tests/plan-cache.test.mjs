import test from 'node:test'
import assert from 'node:assert/strict'
import {PLAN_CACHE_KEY,readTrainingPlan,rememberTrainingPlan,clearTrainingPlan} from '../src/training/planCache.js'

test('plan cache contains training context only and rejects another day',()=>{
 const previous=Object.getOwnPropertyDescriptor(globalThis,'localStorage'),map=new Map()
 Object.defineProperty(globalThis,'localStorage',{configurable:true,value:{getItem:k=>map.get(k),setItem:(k,v)=>map.set(k,v)}})
 try{
  const date=new Intl.DateTimeFormat('en-CA',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date())
  const value={date,timezone:'America/New_York',plan:{slots:[],current:{letter:'E',optional:true}},action:{template_id:'personal-company-e'},days:[],today:{hrv:30},recovery:{score:87}}
  assert.equal(rememberTrainingPlan(value),value)
  assert.equal(readTrainingPlan().plan.current.letter,'E')
  assert.doesNotMatch(map.get(PLAN_CACHE_KEY),/hrv|recovery|87/)
  clearTrainingPlan();assert.equal(readTrainingPlan().action.template_id,'personal-company-e')
  clearTrainingPlan();map.set(PLAN_CACHE_KEY,JSON.stringify({...value,date:'2020-01-01'}))
  assert.equal(readTrainingPlan(),null)
 }finally{clearTrainingPlan();if(previous)Object.defineProperty(globalThis,'localStorage',previous);else delete globalThis.localStorage}
})
