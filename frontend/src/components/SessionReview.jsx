import { sessionReview } from '../training/review'
import '../training/progress.css'
import {isPosture} from '../training/ux'
import {actionableReview} from '../training/actionableReview'

export default function SessionReview({ session, history, reviewState = {} }) {
  const review = sessionReview(session, history)
  const { data, error, retry } = reviewState
  const posture=isPosture(session)
  const analysis = !posture&&data?.status === 'ready' ? data.analysis : null
  const evidence = data?.evidence
  const fallback=actionableReview(session,history,evidence)
  const refs = new Set(analysis ? Object.values(analysis).flatMap(line => line.evidence_ids) : [])
  const facts = evidence?.facts?.filter(f => refs.has(f.id)) || []
  return <section className="st-review" aria-label="训练后分析">
    <header><h3>{analysis ? 'AI 复盘' : '本次复盘'}</h3>{data?.status === 'pending' && <span role="status">AI 分析中…</span>}</header>
    {posture?<p className="st-review-focus">完成 {review.completed}/{review.planned} 练习组，保持舒适、稳定的活动范围。</p>:<dl className="st-review-lines">{[['today','本次'],['trend',evidence?.facts?.some(f=>f.kind==='trend')?'趋势':'对比'],['next','下次']].map(([key,label])=><div key={key}><dt>{label}</dt><dd title={(analysis||fallback)[key].text}>{(analysis||fallback)[key].text}</dd></div>)}</dl>}
    {(error || data?.status === 'error') && <button className="st-text-button st-review-retry" onClick={retry}>AI 暂不可用 · 稍后重试</button>}
    {analysis && <details className="st-review-evidence"><summary>查看分析依据</summary>
      <p>{Object.values(analysis).map(v=>v.text).join('')}</p>
      <ul>{facts.map(f => <li key={f.id}>{f.text}{f.comparison && <small>{f.comparison.previous_reps.join(' / ')} → {f.comparison.current_reps.join(' / ')} 次</small>}</li>)}</ul>
      <p>依据本应用中截至本次训练的已完成记录。实际动作质量、余力和休息由你确认。</p>
    </details>}
  </section>
}
