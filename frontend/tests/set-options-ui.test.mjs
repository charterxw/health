import test from 'node:test'
import assert from 'node:assert/strict'
import React,{act,useState} from 'react'
import {JSDOM} from 'jsdom'
import {createServer} from 'vite'

test('group options save zero, clear missing feedback, validate counts and confirm deletion',async()=>{
 const dom=new JSDOM('<div id="root"></div>',{url:'http://localhost/',pretendToBeVisual:true})
 const saved=new Map()
 for(const [key,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,HTMLElement:dom.window.HTMLElement,IS_REACT_ACT_ENVIRONMENT:true})){
  saved.set(key,Object.getOwnPropertyDescriptor(globalThis,key));Object.defineProperty(globalThis,key,{configurable:true,writable:true,value})
 }
 const vite=await createServer({server:{middlewareMode:true,hmr:false,ws:false},logLevel:'error'})
 const {createRoot}=await import('react-dom/client');const root=createRoot(document.getElementById('root'))
 let stored=null,deleted=false
 try{
  const {default:SetOptions}=await vite.ssrLoadModule('/src/components/SetOptions.jsx')
  function Harness(){const [value,setValue]=useState(null);return React.createElement(SetOptions,{movement:{id:'m',name:'卧推',exercise_id:'bench',load_mode:'external',sets:[{id:'s',reps:8,hard_reps:value,completed_at:'recorded'}]},setId:'s',onSave:n=>{stored=n;setValue(n)},onClose(){},onDelete(){deleted=true}})}
  const render=()=>act(async()=>root.render(React.createElement(Harness,{key:Math.random()})))
  const button=name=>[...document.querySelectorAll('button')].find(b=>b.textContent===name)
  const click=async name=>{assert.ok(button(name),name);await act(async()=>button(name).click())}
  const fill=async text=>{const input=document.getElementById('st-hard-reps');await act(async()=>input.focus());await act(async()=>{Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype,'value').set.call(input,text);input.dispatchEvent(new dom.window.Event('input',{bubbles:true}))})}
  await render();assert.equal(document.getElementById('st-hard-reps').value,'')
  await fill('0');await click('保存');assert.equal(stored,0)
  await click('清除记录');assert.equal(stored,null)
  await render();await fill('9');assert.equal(button('保存').disabled,true);assert.match(document.body.textContent,/不能超过本组次数/)
  await fill('2');await click('保存');assert.equal(stored,2)
  await click('删除本组');assert.equal(deleted,false);assert.match(document.body.textContent,/最后一组.*移除此动作/)
  await click('取消');assert.equal(deleted,false)
  await click('删除本组');await click('确认删除本组');assert.equal(deleted,true)
 }finally{
  await act(async()=>root.unmount());await vite.close();dom.window.close()
  for(const [key,descriptor] of saved){if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key]}
 }
})
