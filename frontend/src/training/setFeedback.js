import {clone} from './strength.js'
import {setLabel} from './ux.js'

export const acceptsFeedback = movement => movement.tracking !== 'duration' && movement.training_type !== 'mobility' && !movement.exercise_id?.startsWith('posture-')
export const validHardReps = row => Number.isInteger(row.hard_reps) && row.hard_reps >= 0 && row.hard_reps <= Number(row.reps) && Number(row.reps) > 0
export const groupName = (movement,index) => movement.sets[index].warmup ? `${setLabel(movement,index)}组` : `第 ${setLabel(movement,index)} 组`

export function feedbackSummary(movement) {
  if (!acceptsFeedback(movement)) return ''
  const groups = new Map()
  movement.sets.forEach((row,index) => {
    if (row.hard_reps == null) return
    const text = !validHardReps(row) ? '吃力次数待核对' : row.hard_reps === 0 ? '没有明显吃力' : `最后 ${row.hard_reps} 次明显吃力`
    if (!groups.has(text)) groups.set(text,[])
    groups.get(text).push(groupName(movement,index))
  })
  return [...groups].map(([text,labels]) => `${labels.join('、')}：${text}`).join('；')
}

export function removeSessionSet(session,movementId,setId) {
  const next=clone(session),movement=next.exercises.find(m=>m.id===movementId)
  if (!movement?.sets.some(s=>s.id===setId)) return next
  movement.sets=movement.sets.filter(s=>s.id!==setId)
  if (!movement.sets.length) next.exercises=next.exercises.filter(m=>m.id!==movementId)
  if (next.rest_set_id===setId) {next.rest_set_id=null;next.rest_until=null}
  return next
}
