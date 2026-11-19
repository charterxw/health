import {useState} from 'react'
import Modal from './Modal'
import TrainingNumberInput from './TrainingNumberInput'
import {clone,hasSetValue,isTimed,weightUnitLabel} from '../training/strength'
import {setLabel} from '../training/ux'
export default function RecordCorrection({session,onClose,onSave}){
 const [draft,setDraft]=useState(()=>clone(session)),[error,setError]=useState(''),[closing,setClosing]=useState(false)
 const dirty=JSON.stringify(draft)!==JSON.stringify(session)
 const close=()=>dirty?setClosing(true):onClose()
 function field(mi,si,key,value){const n=value===''?null:Number(value);if(n!==null&&(!Number.isFinite(n)||n<0||(key!=='weight'&&(!Number.isInteger(n)||n<1))||n>(key==='weight'?2000:key==='duration_seconds'?3600:1000)))return false;setDraft(old=>{const next=clone(old);next.exercises[mi].sets[si][key]=n;return next})}
 function save(){if(draft.exercises.some(m=>m.sets.some(s=>s.completed_at&&!hasSetValue(m,s)))){setError('请补齐已完成组的数值，或取消该组的完成标记。');return}onSave(draft)}
 return <Modal title="更正本次记录" onClose={close} wide>
  <p className="st-muted">只修改这场训练的实际记录。</p>
  {closing&&<div className="st-draft-guard"><strong>更正尚未保存</strong><button onClick={()=>setClosing(false)} className="st-secondary">继续编辑</button><button onClick={onClose} className="st-text-button">放弃修改</button></div>}
  <label className="st-notes">训练名称<input maxLength={100} value={draft.title} onChange={e=>setDraft({...draft,title:e.target.value})}/></label>
  {draft.exercises.map((m,mi)=><details key={m.id} className="st-correction-movement" open={mi===0||undefined}><summary>{m.name}</summary>{m.sets.map((s,si)=><div className="st-correction-row" key={s.id}><span>{setLabel(m,si)}</span>{m.load_mode!=='bodyweight'&&!isTimed(m)&&<label>重量 / {weightUnitLabel(m.unit)}<TrainingNumberInput decimal value={s.weight} onValueChange={v=>field(mi,si,'weight',v)}/></label>}<label>{isTimed(m)?'秒数':'次数'}<TrainingNumberInput value={isTimed(m)?s.duration_seconds:s.reps} onValueChange={v=>field(mi,si,isTimed(m)?'duration_seconds':'reps',v)}/></label><label>已完成<input type="checkbox" checked={Boolean(s.completed_at)} onChange={e=>setDraft(old=>{const next=clone(old);next.exercises[mi].sets[si].completed_at=e.target.checked?session.ended_at:null;return next})}/></label></div>)}</details>)}
  <label className="st-notes">笔记<textarea value={draft.notes} maxLength={4000} onChange={e=>setDraft({...draft,notes:e.target.value})}/></label>
  {error&&<p role="alert" className="st-error">{error}</p>}
  <button className="st-primary st-wide" disabled={!draft.title.trim()||!dirty} onClick={save}>保存更正</button>
 </Modal>
}
