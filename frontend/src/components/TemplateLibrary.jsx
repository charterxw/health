import { useMemo } from 'react'
import { templateCounts } from '../training/programs'
import { durationLabel, groupTemplates } from '../training/templateLibrary'
import TrainingPlanGuide from './TrainingPlanGuide'
import '../training/templates.css'

function Chevron({ down = false }) {
  return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" aria-hidden="true"><path d={down ? 'm6 9 6 6 6-6' : 'm9 5 7 7-7 7'} /></svg>
}

function TemplateRow({ record, disabled, onPreview, onEdit, onStart }) {
  const template = record.template, count = templateCounts(template)
  return <article className="st-template-card st-template-compact" data-template-id={template.id}>
    <div className="st-template-title">
      <h3><button className="st-template-preview" aria-label={`查看${template.name}的动作`} onClick={() => onPreview(template)}>{template.name}</button></h3>
      <p>{[durationLabel(template), `${template.exercises.length} 个动作`, `${count.work} ${!template.id.startsWith('posture-') && template.exercises.every(plan => plan.warmup_count != null) ? '工作组' : '组'}`].filter(Boolean).join(' · ')}</p>
    </div>
    <div className="st-template-launch">
      <button className="st-template-edit" aria-label={`编辑${template.name}`} onClick={() => onEdit(record)}>编辑</button>
      <button className="st-primary" disabled={disabled} aria-label={`开始${template.name}训练`} onClick={() => onStart(template)}>开始训练</button>
    </div>
  </article>
}

export default function TemplateLibrary({ templates, exercises, routine, disabled, onPreview, onEdit, onStart }) {
  const groups = useMemo(() => groupTemplates(templates), [templates])
  const row = record => <TemplateRow key={record.template.id} record={record} disabled={disabled} onPreview={onPreview} onEdit={onEdit} onStart={onStart} />
  return <section className="st-template-library" aria-label="训练模板库">
    <div className="st-template-grid st-template-groups">{groups.map(group => <details key={group.id} className="st-template-group" name="training-template-groups" data-template-group={group.id}>
      <summary><span className={`st-template-group-mark ${group.letter ? '' : 'is-other'}`}>{group.letter || (group.id === 'posture' ? '体态' : group.id === 'weekend' ? '周末' : '其他')}</span><span className="st-template-group-copy"><strong>{group.letter ? group.focus || group.label : group.label}</strong><small>{group.letter ? `${group.locations}${group.letter==='E'?' · 可选':''}` : group.id === 'posture' ? '日常练习 + 独立 Y 字举' : ''}</small></span>{group.records.some(record => record.template.id === routine?.record?.template.id) && <span className="st-template-next">当前</span>}<span className="st-template-group-chevron"><Chevron down /></span></summary>
      <div className="st-template-group-rows">{group.records.map(row)}</div>
    </details>)}</div>
    <TrainingPlanGuide />
  </section>
}
