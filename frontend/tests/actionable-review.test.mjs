import test from 'node:test'
import assert from 'node:assert/strict'
import {startSession} from '../src/training/strength.js'
import {actionableReview} from '../src/training/actionableReview.js'
const make=()=>{const s=startSession({id:'a',exercises:[{exercise_id:'raise',set_count:3}]},[{id:'raise',name:'哑铃侧平举',load_mode:'external'}]);Object.assign(s,{status:'completed',started_at:'2026-11-15T12:00:00Z',ended_at:'2026-11-15T12:30:00Z'});s.exercises[0].sets.forEach((r,i)=>Object.assign(r,{weight:10,reps:[12,12,10][i],completed_at:s.ended_at}));return s}
test('review names actual load, per-set reps and a specific next group',()=>{
 const s=make(),r=actionableReview(s)
 assert.match(r.today.text,/哑铃侧平举.*10 磅.*12／12／10/)
 assert.match(r.next.text,/第 3 组尝试 11 次/)
 s.exercises[0].sets[2].hard_reps=2
 assert.match(actionableReview(s).next.text,/自报吃力.*10 磅 × 10 次/)
})
test('ready structured next focus is used while AI is pending',()=>{
 const r=actionableReview(make(),[],{next_focus:'m0-next',facts:[{id:'m0-next',kind:'next',text:'哑铃侧平举：下次第3组先完成10磅×11次。'}]})
 assert.equal(r.next.text,'哑铃侧平举：下次第3组先完成10磅×11次。')
})
