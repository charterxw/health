import test from 'node:test'
import assert from 'node:assert/strict'
import {startSession,appendExerciseSet} from '../src/training/strength.js'
import {sessionTemplate} from '../src/training/programs.js'
import {removeSessionSet,feedbackSummary} from '../src/training/setFeedback.js'
const exercise={id:'bench',name:'卧推',load_mode:'external'}
const make=()=>startSession({id:'a',name:'A',exercises:[{exercise_id:'bench',set_count:4,warmup_count:1,target_reps:8}]},[exercise])

test('removing a set preserves other rest, removes its own timer and permits deleting the final row',()=>{
 const s=make(),m=s.exercises[0];s.rest_set_id=m.sets[3].id;s.rest_until=new Date(Date.now()+60000).toISOString()
 let next=removeSessionSet(s,m.id,m.sets[0].id)
 assert.equal(next.rest_until,s.rest_until);assert.equal(next.exercises[0].sets.length,3);assert.equal(s.exercises[0].sets.length,4)
 next=removeSessionSet(next,m.id,m.sets[3].id);assert.equal(next.rest_until,null);assert.equal(next.rest_set_id,null)
 for(const row of [...next.exercises[0].sets])next=removeSessionSet(next,m.id,row.id)
 assert.deepEqual(next.exercises,[])
})
test('feedback distinguishes missing from zero and flags changed repetition counts',()=>{
 const m=make().exercises[0];assert.equal(feedbackSummary(m),'')
 m.sets[1].hard_reps=0;m.sets[2].hard_reps=2;m.sets[3].hard_reps=2
 assert.match(feedbackSummary(m),/第 1 组：没有明显吃力/)
 assert.match(feedbackSummary(m),/第 2 组、第 3 组：最后 2 次明显吃力/)
 m.sets[2].reps=1;assert.match(feedbackSummary(m),/第 2 组：吃力次数待核对/)
})
test('new rows, repeated workouts and templates do not inherit subjective feedback',()=>{
 const s=make(),m=s.exercises[0];m.sets.at(-1).hard_reps=3
 assert.equal(appendExerciseSet(m).sets.at(-1).hard_reps,null)
 const template=sessionTemplate(s);assert.doesNotMatch(JSON.stringify(template),/hard_reps/)
 assert.ok(startSession(template,[exercise],[{session:s}]).exercises[0].sets.every(row=>row.hard_reps==null))
})
