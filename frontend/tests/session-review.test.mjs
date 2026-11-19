import test from 'node:test'
import assert from 'node:assert/strict'
import React from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { createServer } from 'vite'
import { startSession, newSet } from '../src/training/strength.js'
import { movementHeadlines } from '../src/training/conciseReview.js'

function sample() {
  const exercise={id:'raise',name:'哑铃侧平举',load_mode:'external'}
  const s=startSession({id:'home',name:'家庭训练',exercises:[{exercise_id:'raise',set_count:4}]},[exercise])
  s.status='completed';s.started_at='2026-11-14T12:00:00Z';s.ended_at='2026-11-14T12:26:00Z'
  s.exercises[0].prescription={rep_min:12,rep_max:20,increment:2.5,work_sets:4}
  s.exercises[0].sets=Array.from({length:4},()=>newSet({weight:10,reps:12,completed_at:s.ended_at}))
  return s
}

test('concise movement summaries honor saved authoritative evidence and do not invent progress',()=>{
  const s=sample(),id=s.exercises[0].id
  assert.equal(movementHeadlines(s,[]).get(id),'完成4组，保持重量继续补次数')
  assert.equal(movementHeadlines(s,[],{items:[{id,headline:'组数或目标有变化，本次作为新基准'}]}).get(id),'组数或目标有变化，本次作为新基准')
})

test('AI review has three short lines with collapsed evidence; fallback never claims to be AI',async()=>{
  const vite=await createServer({server:{middlewareMode:true,hmr:false,ws:false},logLevel:'error',optimizeDeps:{noDiscovery:true,include:[]}})
  try {
    const {default:Review}=await vite.ssrLoadModule('/src/components/SessionReview.jsx')
    const s=sample()
    const analysis={today:{text:'各组完成目标次数。',evidence_ids:['session']},trend:{text:'暂不足以判断持续趋势。',evidence_ids:['missing']},next:{text:'保持各组重量，争取多做次数。',evidence_ids:['next']}}
    const html=renderToStaticMarkup(React.createElement(Review,{session:s,history:[],reviewState:{data:{status:'ready',analysis,evidence:{facts:[{id:'session',text:'完成4/4组。'}]}}}}))
    assert.match(html,/AI 复盘/);assert.equal((html.match(/<dd(?:\s[^>]*)?>/g)||[]).length,3)
    assert.match(html,/<details class="st-review-evidence">/);assert.doesNotMatch(html,/<details open/)
    const fallback=renderToStaticMarkup(React.createElement(Review,{session:s,history:[]}))
    assert.match(fallback,/本次复盘/);assert.doesNotMatch(fallback,/AI 复盘|已保存目标|上次包含不同重量/)
  } finally {await vite.close()}
})
