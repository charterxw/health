import { buildTrainingReport } from './report.js'
import { sessionReview } from './review.js'

export function movementHeadlines(session, history, serverEvidence) {
  if (serverEvidence?.items) return new Map(serverEvidence.items.map(item => [item.id, item.headline]))
  const report=buildTrainingReport(session,history)
  const review = sessionReview(session, history)
  return new Map(review.items.map((item, index) => {
    const m = session.exercises[index]
    if (m.training_type === 'mobility' || m.tracking === 'duration') return [item.id, `完成${item.count}/${item.planned}组，按舒适范围继续练习`]
    const change=report.movements.find(row=>row.id===m.id)?.comparison
    if(change?.repDelta!=null){const base=change.kind==='bodyweight'?'自重':`${change.weight} ${m.unit==='kg'?'公斤':'磅'} · ${change.currentReps.length} 组`;return [item.id,change.repDelta?`${base}，${change.repDelta>0?'多':'少'} ${Math.abs(change.repDelta)} 次`:`${base}，与上次持平`]}
    let text = !item.count ? '未完成工作组' : item.count < item.planned ? `完成${item.count}/${item.planned}组，先完成计划组数`
      : item.target?.top === item.planned ? (m.load_mode === 'bodyweight' ? '各组达到次数上限，可调整目标' : '各组达到次数上限，可考虑小幅加重')
        : item.target && item.target.met < item.count ? '部分组未到目标下限，先稳住次数' : `完成${item.count}组，保持重量继续补次数`
    if (m.load_mode === 'assistance') text = text.replace('可考虑小幅加重', '可考虑减少辅助量')
    return [item.id,text]
  }))
}

export function overallHeadline(review, evidence) {
  const positive = evidence?.facts.find(f => f.kind === 'comparison' && f.comparison?.delta > 0)
  if (positive) return positive.text.split('；')[0] + '。'
  if (!review.completed) return '本次没有已完成的工作组。'
  if (review.completed < review.planned) return `完成${review.completed}/${review.planned}个工作组，下次先完成当前安排。`
  const top = review.items.find(item => item.target?.top === item.planned && item.count === item.planned)
  if (top) return `${top.name}各组达到次数上限，可结合动作和余力调整下一次目标。`
  return '已完成本次安排，下次先沿用各组重量。'
}
