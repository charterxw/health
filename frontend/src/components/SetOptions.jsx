import {useState} from 'react'
import Modal from './Modal'
import TrainingNumberInput from './TrainingNumberInput'
import {setLabel} from '../training/ux'
import {acceptsFeedback,groupName} from '../training/setFeedback'

export function SetNumber({movement,index,onClick}) {
 const row=movement.sets[index],marked=acceptsFeedback(movement)&&row.hard_reps!=null
 return <button type="button" className={`st-set-number st-set-options-trigger ${row.warmup?'warmup':''}`} aria-haspopup="dialog" aria-label={`${movement.name} · ${groupName(movement,index)}操作${marked?'，已记录表现':''}`} onClick={onClick}>
  {setLabel(movement,index)}{marked&&<span className="st-set-feedback-dot" aria-hidden="true"/>}
 </button>
}

export default function SetOptions({movement,setId,onSave,onDelete,onClose}) {
 const index=movement.sets.findIndex(s=>s.id===setId),row=movement.sets[index]
 const [value,setValue]=useState(row?.hard_reps??''),[deleting,setDeleting]=useState(false)
 if (!row) return null
 const canRecord=acceptsFeedback(movement),n=value===''?null:Number(value)
 const error=n!==null&&(!Number.isInteger(n)||n<0||n>1000)?'请填写 0–1000 之间的整数。':n!==null&&(!(row.reps>0)||n>row.reps)?'吃力次数不能超过本组次数，请核对后保存。':''
 return <Modal title={groupName(movement,index)} onClose={onClose}>
  <div className="st-set-options">
   <p className="st-set-options-name">{movement.name}</p>
   {deleting?<>
    <p className="st-confirm-text">{movement.sets.length===1?'这是该动作最后一组，删除后也会移除此动作。':row.completed_at?'这一组已完成，删除后会从本次训练记录中移除。':'删除本次训练中的这一组？'}</p>
    <div className="st-confirm-buttons"><button className="st-secondary" onClick={()=>setDeleting(false)}>取消</button><button className="st-danger" onClick={onDelete}>确认删除本组</button></div>
   </>:<>
    {canRecord&&<>
     <label htmlFor="st-hard-reps">最后几次明显吃力 <small>选填</small></label>
     <TrainingNumberInput id="st-hard-reps" aria-describedby="st-hard-reps-hint" placeholder="未记录" value={value} enterKeyHint="done" onValueChange={v=>{setValue(v);return true}}/>
     <p id="st-hard-reps-hint" className="st-muted">填 0 表示没有明显吃力，留空不记录。</p>
     {error&&<p className="st-error" role="alert">{error}</p>}
     <div className="st-confirm-buttons"><button className="st-secondary" disabled={row.hard_reps==null&&value===''} onClick={()=>onSave(null)}>清除记录</button><button className="st-primary" disabled={Boolean(error)} onClick={()=>onSave(n)}>保存</button></div>
    </>}
    <button className="st-set-delete" onClick={()=>setDeleting(true)}>删除本组</button>
   </>}
  </div>
 </Modal>
}
