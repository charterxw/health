import test from 'node:test'
import assert from 'node:assert/strict'
import React, { act } from 'react'
import { JSDOM } from 'jsdom'
import { createServer } from 'vite'

test('home keeps today separate from selected history, links training, saves dated goals and optional feedback', async()=>{
 const dom=new JSDOM('<div id="root"></div>',{url:'http://localhost/',pretendToBeVisual:true}),{window}=dom,{document}=window
 const previous=new Map(),writes=[]
 const goals={dailyActivity:300,weeklyActivity:2100,weeklyStrength:4,weeklyPosture:4}
 let data={date:'2026-11-15',timezone:'America/New_York',today:{steps:4000,sleep_hours:8},days:Array.from({length:7},(_,i)=>({date:`2026-11-${9+i}`,activity:200,sets:i===6?7:0,target:i===6?14:0,short:i===6?'家':'休',strength_planned:i===6,posture:false,posture_planned:i===6,goals,sessions:[]})),metrics:[],sleep:null,sleeps:[],weights:[],walks:[],recovery:{score:78,label:'平稳'},step_goal:{target:6500,basis:'按近期步数初始化'},feedback:{},plan:{done:7,target:54,slots:[],next:{short:'家',done:0,target:7}},tip:'今天还剩家庭训练，晚上接着完成。',action:{template_id:'personal-home-d',remaining:[]},goals,next_goals:null,next_effective:'2026-11-16',sources:{metrics:{fetched_at:null}}}
 const brief={date:'2026-11-15',period:'morning',status:'ready',sentences:[{text:'昨夜睡眠充足，近期作息稳定。',evidence_ids:['sleep']},{text:'今天按计划休息，遛狗照常。',evidence_ids:['guidance']}],generated_at:'2026-11-15T10:00:00-05:00'}
 data.freshness={records:{steps:{observed_at:'2026-11-15T15:00:00Z'}}}
 let completeRefresh;const pendingRefresh=new Promise(resolve=>{completeRefresh=resolve})
 const fetch=async(url,options={})=>{if(url==='/api/home/refresh')await pendingRefresh;if(url.startsWith('/api/home/brief'))return {ok:true,status:200,json:async()=>structuredClone(brief)};if(options.body){writes.push({url,value:JSON.parse(options.body)});if(url.endsWith('/step-goal'))data={...data,step_goal:{...data.step_goal,...JSON.parse(options.body)}};if(url.endsWith('/goals'))data={...data,next_goals:JSON.parse(options.body)};if(url.endsWith('/feedback'))data={...data,feedback:{...data.feedback,...JSON.parse(options.body)}}}return {ok:true,status:200,json:async()=>structuredClone(data)}}
 for(const [key,value] of Object.entries({window,document,navigator:window.navigator,IS_REACT_ACT_ENVIRONMENT:true,fetch})){previous.set(key,Object.getOwnPropertyDescriptor(globalThis,key));Object.defineProperty(globalThis,key,{configurable:true,writable:true,value})}
 const vite=await createServer({server:{middlewareMode:true,hmr:false,ws:false},logLevel:'error',optimizeDeps:{noDiscovery:true,include:[]}})
 const {createRoot}=await import('react-dom/client');const root=createRoot(document.getElementById('root'))
 try{
  const {default:Dashboard,rhythm,weightWeeks,briefPreview,latestRead,retainBrief}=await vite.ssrLoadModule('/src/components/Dashboard.jsx')
  const actions=[]
  await act(async()=>{root.render(React.createElement(Dashboard,{onTraining:a=>actions.push(a)}));await new Promise(r=>setTimeout(r,20))})
  const syncButton=document.querySelector('.home-heading button')
  assert.equal(syncButton.getAttribute('aria-busy'),'true')
  assert.match(syncButton.textContent,/正在同步/)
  assert.doesNotMatch(syncButton.textContent,/活动记录/)
  assert.ok(syncButton.querySelector('.home-sync-spinner'))
  // Cached timestamps exist, but they cannot conceal an outstanding refresh.
  await act(async()=>{completeRefresh();await new Promise(r=>setTimeout(r,20))})
  assert.equal(syncButton.getAttribute('aria-busy'),'false')
  assert.match(syncButton.textContent,/活动记录/)
  assert.equal(syncButton.querySelector('.home-sync-spinner'),null)
  assert.equal(document.querySelectorAll('.home-days button').length,7)
  assert.equal(document.querySelectorAll('.home-rings').length,7)
  assert.equal(document.querySelector('.home-posture'),null)
  assert.equal(latestRead({metrics:{fetched_at:'2026-11-15T10:00:00-05:00'},activity:{fetched_at:'2026-11-15T15:01:00Z'},sleep:{fetched_at:'invalid'}}),'2026-11-15T15:01:00Z')
  assert.equal(latestRead({metrics:{fetched_at:null}}),null)
  assert.equal(retainBrief(brief,{...brief,status:'pending',sentences:[]}),brief)
  assert.notEqual(retainBrief(brief,{...brief,date:'2026-11-16',status:'pending',sentences:[]}),brief)
  await act(async()=>document.querySelectorAll('.home-table th button')[2].click())
  assert.match(document.querySelector('[role="dialog"]').textContent,/完成体态训练后自动计入/)
  assert.doesNotMatch(document.querySelector('[role="dialog"]').textContent,/打卡|记录今天已完成/)
  await act(async()=>document.querySelector('.home-dialog .home-primary').click())
  assert.deepEqual(actions.pop(),{template_id:'posture-daily'})
  assert.doesNotMatch(document.querySelector('.home-tiles').textContent,/昨夜睡眠|作息规律|体重/)
  assert.doesNotMatch(document.querySelector('.home-goals').textContent,/千卡|本轮方案/)
  assert.match(document.querySelector('.home-steps').textContent,/4,000.*6,500/)
  assert.doesNotMatch(document.querySelector('.home-tip').textContent,/恢复.*78/)
  assert.deepEqual(briefPreview([{text:'训练完成10组',evidence_ids:['training-today']},{text:'静息心率较平时偏高',evidence_ids:['resting_hr-trend']},{text:'今晚按时休息',evidence_ids:['guidance']}],'备用'),['静息心率较平时偏高','今晚按时休息'])
  await act(async()=>document.querySelector('.home-recovery button').click())
  assert.match(document.querySelector('[role="dialog"]').textContent,/恢复指数.*78.*HRV.*静息心率/s)
  await act(async()=>document.querySelector('[aria-label="关闭"]').click())
  await act(async()=>document.querySelector('.home-steps button').click())
  const input=document.querySelector('.home-step-goal-form input')
  await act(async()=>{Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set.call(input,'8000');input.dispatchEvent(new window.Event('input',{bubbles:true}))})
  await act(async()=>document.querySelector('.home-step-goal-form').dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true})))
  assert.deepEqual(writes.at(-1),{url:'/api/home/step-goal',value:{target:8000}})
  assert.match(document.querySelector('.home-steps').textContent,/8,000/)
  const tip=document.querySelector('.home-brief-text');const todayTip=tip.textContent
  assert.doesNotMatch(document.querySelector('.home-tip').textContent,/下次训练|剩余/)
  await act(async()=>document.querySelectorAll('.home-days button')[1].click())
  assert.match(document.querySelector('.home-table thead').textContent,/周二 · 10日/)
  assert.match(document.querySelector('.home-table').textContent,/休息日/)
  assert.equal(tip.textContent,todayTip)
  await act(async()=>tip.click());assert.equal(actions.length,0)
  assert.ok(document.querySelector('[role="dialog"]'))
  await act(async()=>document.querySelector('[aria-label="关闭"]').click())
  await act(async()=>document.querySelector('.home-feedback').click())
  const buttons=[...document.querySelectorAll('.home-choices button')]
  await act(async()=>buttons.find(b=>b.textContent==='困倦').click())
  await act(async()=>document.querySelector('.home-dialog .home-primary').click())
  assert.deepEqual(writes.at(-1),{url:'/api/home/feedback',value:{energy:'困倦',fatigue:null}})
  assert.match(document.querySelector('.home-recovery').textContent,/78/)
  await act(async()=>document.querySelector('[aria-label="调整下周目标"]').click())
  assert.match(document.querySelector('[role="dialog"]').textContent,/保留本周与过去/)
  await act(async()=>document.querySelector('.home-form').dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true})))
  assert.equal(writes.at(-1).url,'/api/home/goals');assert.equal(data.goals.dailyActivity,300)
  const {default:TrainingRound}=await vite.ssrLoadModule('/src/components/TrainingRound.jsx')
  await act(async()=>root.render(React.createElement(TrainingRound,{active:true,onTraining:a=>actions.push(a)})))
  await act(async()=>document.querySelector('[aria-label="查看本轮进度"]').click())
  assert.match(document.querySelector('[role="dialog"]').textContent,/本轮进度.*7 \/ 54 组/s)
  await act(async()=>document.querySelector('.home-dialog .home-primary').click())
  assert.deepEqual(actions.at(-1),data.action)
  assert.equal(document.querySelector('[role="dialog"]'),null)
  assert.equal(rhythm([{date:'1',start_time:'2026-11-10T04:50:00Z',start_utc_offset:'-18000s'},{date:'2',start_time:'2026-11-11T05:10:00Z',start_utc_offset:'-18000s'},{date:'3',start_time:'2026-11-12T05:00:00Z',start_utc_offset:'-18000s'},{date:'4',start_time:'2026-11-13T05:00:00Z',start_utc_offset:'-18000s'}]).deviation,5)
  assert.equal(weightWeeks([{date:'2026-11-09',kg:68},{date:'2026-11-10',kg:70}])[0].kg,69)
 }finally{await act(async()=>root.unmount());await vite.close();dom.window.close();for(const[key,descriptor]of previous){if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key]}}
})
