import {buildTrainingReport} from './report.js'
import {hasSetValue,weightUnitLabel} from './strength.js'
import {validHardReps} from './setFeedback.js'
import {workProgress} from './ux.js'

const load=(m,s)=>m.load_mode==='bodyweight'?'自重':`${m.load_mode==='assistance'?'辅助 ':''}${s.weight} ${weightUnitLabel(m.unit)}`
export function actionableReview(session,history=[],evidence) {
 const report=buildTrainingReport(session,history),facts=evidence?.facts||[]
 const movements=session.exercises.filter(m=>m.training_type!=='mobility'&&m.tracking!=='duration')
 const completed=m=>m.sets.filter(s=>!s.warmup&&s.completed_at&&hasSetValue(m,s))
 const nextFact=facts.find(f=>f.id===evidence?.next_focus)
 const changed=report.movements.find(m=>m.comparison?.repDelta!=null&&m.comparison.repDelta!==0)
 const focus=movements.find(m=>nextFact?.text.startsWith(m.name))||movements.find(m=>/侧平举|弯举|臂屈伸|下压/.test(m.name)&&completed(m).length)||movements.find(m=>completed(m).length)
 const main=changed||focus,rows=main?completed(main):[]
 const uniform=rows.length&&rows.every(s=>s.weight===rows[0].weight)
 const today=rows.length?`${main.name}：${uniform?`${load(main,rows[0])}，${rows.map(s=>s.reps).join('／')} 次`:rows.map(s=>`${load(main,s)} × ${s.reps}`).join('；')}。`:`本次完成 ${workProgress(session).done} 个工作组。`
 const trendFact=facts.find(f=>f.kind==='trend')||facts.find(f=>f.kind==='comparison')
 const change=changed?.comparison
 let trend=trendFact?.text||(change?`${changed.name}较上次相同组数${change.kind==='bodyweight'?'自重':'同重量'}，${change.repDelta>0?'多':'少'} ${Math.abs(change.repDelta)} 次。`:null)
 if(!trend&&main&&rows.length>1){trend=`${main.name}${uniform?'同负荷下，':''}首组 ${rows[0].reps} 次，末组 ${rows.at(-1).reps} 次。`}
 if(!trend)trend=rows.length?`${main.name}本次记录作为下一次同模板对照。`:'结束后可回看每个动作的实际组次。'
 let next=nextFact?.text
 if(!next&&focus){
  const planned=focus.sets.filter(s=>!s.warmup),done=completed(focus),pending=planned.findIndex(s=>!s.completed_at)
  if(pending>=0){const row=planned[pending];next=`${focus.name}下次先完成第 ${pending+1} 组${hasSetValue(focus,row)?`：${load(focus,row)} × ${row.reps} 次`:''}。`}
  else if(done.length){let i=done.findLastIndex(s=>validHardReps(s)&&s.hard_reps>0);if(i>=0){const row=done[i];next=`${focus.name}第 ${i+1} 组自报吃力，下次先稳住 ${load(focus,row)} × ${row.reps} 次。`}
   else {i=done.reduce((best,s,n)=>s.reps<=done[best].reps?n:best,0);const row=done[i],limit=focus.prescription?.rep_max;next=limit&&done.every(s=>s.reps>=limit)?`${focus.name}各组已达 ${limit} 次，动作稳定且有余力时考虑最小步长加重。`:`${focus.name}先保持负荷，动作稳定且有余力时第 ${i+1} 组尝试 ${Math.min(1000,row.reps+1,limit||1000)} 次。`}
  }
 }
 return {today:{text:today},trend:{text:trend},next:{text:next||'下次从未完成的动作继续记录。'}}
}
