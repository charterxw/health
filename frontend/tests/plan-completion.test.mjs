import test from 'node:test'
import assert from 'node:assert/strict'
import React, {act} from 'react'
import {JSDOM} from 'jsdom'
import {createServer} from 'vite'

test('confirmed old-template completion shows the next pair and keeps actual group counts', async()=>{
 const dom=new JSDOM('<div id="root"></div>',{url:'http://localhost/',pretendToBeVisual:true})
 const slots=['A 公司','A 家庭','B 公司','B 家庭'].map((name,i)=>({name,template_id:String(i),done:i===0?9:i===1?6:0,target:9,remaining:[],completed:i<2,completion_confirmed:i===1}))
 const data={days:[],date:'2026-11-17',plan:{slots,done:15,target:72,next:slots[2]},action:{template_id:'2'}}
 const saved=new Map()
 for(const [key,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,HTMLElement:dom.window.HTMLElement,IS_REACT_ACT_ENVIRONMENT:true,fetch:async()=>({ok:true,json:async()=>data})})){
  saved.set(key,Object.getOwnPropertyDescriptor(globalThis,key));Object.defineProperty(globalThis,key,{configurable:true,writable:true,value})
 }
 const vite=await createServer({server:{middlewareMode:true,hmr:false,ws:false},logLevel:'error'})
 const {createRoot}=await import('react-dom/client');const root=createRoot(document.getElementById('root'))
 try{
  const {default:TrainingRound}=await vite.ssrLoadModule('/src/components/TrainingRound.jsx')
  await act(async()=>root.render(React.createElement(TrainingRound,{active:true})))
  assert.match(document.querySelector('.st-current-plan').textContent,/15 \/ 72/)
  assert.match(document.querySelector('.st-current-plan').textContent,/B 公司/)
  assert.doesNotMatch(document.querySelector('.st-current-plan').textContent,/A 家庭/)
  await act(async()=>document.querySelector('[aria-label="查看本轮进度"]').click())
  assert.match(document.querySelector('[role="dialog"]').textContent,/A 家庭已完成 · 按当日模板/)
 }finally{
  await act(async()=>root.unmount());await vite.close();dom.window.close()
  for(const [key,descriptor] of saved){if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key]}
 }
})
