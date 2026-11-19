import { useEffect, useRef, useState } from 'react'
import { getObservationArchive, getTodayInsights, getWeeklyObservation, triggerInsight, triggerWeeklyObservation } from '../api/client'
import { SunriseIcon, MoonIcon } from './Icons'
import HealthIcon from './HealthIcon'
import Observation from './Observation'
import './observations.css'

const sections = {
  morning: { label: '早间', topic: '昨夜睡眠', Icon: SunriseIcon,
    empty: '主睡眠同步后，结合近期记录看昨夜的睡眠时长和结构。', schedule: '每天 08:30 起' },
  evening: { label: '晚间', topic: '活动与训练', Icon: MoonIcon,
    empty: '回看全天活动与健康表现。有力量训练时，结合昨夜睡眠和当天数据分析。', schedule: '每天 21:00' },
  weekly: { label: '每周', topic: '七天趋势',
    empty: '回看最近七个完整日，与此前数周的睡眠、恢复和训练对照。', schedule: '每周一 09:00' },
}
const archiveLabels = { morning: '早间分析', sleep: '睡眠分析', noon: '旧午间分析', evening: '晚间分析', weekly: '每周观察', training: '训练分析' }

function SleepTrend({ points }) {
  if (!points?.some(point => point.minutes != null)) return null
  const max = Math.max(...points.map(point => point.minutes || 0), 1)
  return <details className="observation-trend">
    <summary>查看逐晚睡眠（小时）</summary>
    <div className="observation-trend-chart" role="img" aria-label={points.map(point =>
      `${point.date} ${point.minutes == null ? '缺失' : `${point.minutes} 分钟`}`).join('，')}>
      {points.map(point => <div key={point.date} aria-hidden="true">
        <span>{point.minutes == null ? '—' : (point.minutes / 60).toFixed(1)}</span>
        <i data-missing={point.minutes == null} style={{ height: point.minutes == null ? 3 : point.minutes / max * 68 }} />
        <span>{point.date.slice(5).replace('-', '/')}</span>
      </div>)}
    </div>
  </details>
}

export default function AITimeline() {
  const [requested] = useState(() => {
    const value = new URLSearchParams(globalThis.window?.location.search).get('observation')
    return Object.hasOwn(sections, value) ? value : null
  })
  const [selected, setSelected] = useState(requested)
  const [reports, setReports] = useState({})
  const [pending, setPending] = useState({ daily: true, weekly: true })
  const [loadErrors, setLoadErrors] = useState({})
  const [attempt, setAttempt] = useState(0)
  const [generating, setGenerating] = useState(null)
  const [generationErrors, setGenerationErrors] = useState({})
  const [archiveOpen, setArchiveOpen] = useState(false)
  const [archive, setArchive] = useState(null)
  const [archiveError, setArchiveError] = useState(false)
  const [archiveAttempt, setArchiveAttempt] = useState(0)
  const [archiveLimit, setArchiveLimit] = useState(12)
  const sectionRef = useRef(null)
  const headingRef = useRef(null)

  useEffect(() => {
    const controller = new AbortController()
    setPending({ daily: true, weekly: true })
    setLoadErrors({})
    const load = (key, request, apply) => request.then(data => {
      if (!controller.signal.aborted) apply(data)
    }).catch(() => {
      if (!controller.signal.aborted) setLoadErrors(old => ({ ...old, [key]: true }))
    }).finally(() => {
      if (!controller.signal.aborted) setPending(old => ({ ...old, [key]: false }))
    })
    load('daily', getTodayInsights(controller.signal), items => setReports(old => ({
      ...old, ...Object.fromEntries(items.map(item => [item.time_slot, item])),
    })))
    load('weekly', getWeeklyObservation(controller.signal), report => {
      if (report.available !== false) setReports(old => ({ ...old, weekly: report }))
    })
    return () => controller.abort()
  }, [attempt])

  useEffect(() => {
    if (!requested) return
    const frame = window.requestAnimationFrame(() => {
      sectionRef.current?.scrollIntoView?.({ block: 'start' })
      headingRef.current?.focus({ preventScroll: true })
    })
    return () => window.cancelAnimationFrame(frame)
  }, [requested])

  useEffect(() => {
    if (!archiveOpen || archive) return
    const controller = new AbortController()
    setArchiveError(false)
    getObservationArchive(controller.signal).then(items => {
      if (!controller.signal.aborted) setArchive(items)
    }).catch(() => {
      if (!controller.signal.aborted) setArchiveError(true)
    })
    return () => controller.abort()
  }, [archiveOpen, archive, archiveAttempt])

  const slot = selected ?? (reports.evening ? 'evening' : 'morning')
  const tab = sections[slot]
  const report = reports[slot]
  const historical = archive?.filter(item => !Object.values(reports).some(current =>
    current.date === item.date && current.title === item.title))
  const group = slot === 'weekly' ? 'weekly' : 'daily'
  const period = report?.report?.period
  const reportDate = slot === 'weekly' && period ? `${period.start} 至 ${period.end}`
    : [report?.date, report?.report?.as_of && `截至 ${report.report.as_of}`].filter(Boolean).join(' · ')

  async function generate() {
    setSelected(slot)
    setGenerating(slot)
    setGenerationErrors(old => ({ ...old, [slot]: '' }))
    try {
      const result = await (slot === 'weekly' ? triggerWeeklyObservation() : triggerInsight(slot))
      setReports(old => ({ ...old, [slot]: result }))
      setArchive(null)
    } catch (failure) {
      setGenerationErrors(old => ({ ...old, [slot]: failure.message || '暂时无法生成分析，请重试。' }))
    } finally {
      setGenerating(null)
    }
  }

  return <section ref={sectionRef} id="today-observations" className="observation-panel" aria-labelledby="observation-heading">
    <h2 ref={headingRef} tabIndex={-1} id="observation-heading">今日观察</h2>
    <div className="observation-switch" role="group" aria-label="观察类型">
      {Object.entries(sections).map(([key, { label, topic, Icon }]) =>
        <button type="button" key={key} aria-pressed={slot === key} onClick={() => setSelected(key)}>
          {Icon ? <Icon size={17} aria-hidden="true" /> : <HealthIcon name="calendar" size={17} />}
          <span><strong>{label}</strong><small>{topic}</small></span>
        </button>
      )}
    </div>

    <div className="observation-reading">
      <div className="observation-reading-head">
        <div><h3>{tab.topic}</h3><p>{report ? reportDate : tab.schedule}</p></div>
        <button type="button" className="observation-action"
          disabled={pending[group] || generating !== null}
          onClick={loadErrors[group] && !report ? () => setAttempt(value => value + 1) : generate}>
          {generating === slot ? '分析中…' : loadErrors[group] && !report ? '重试读取' : report ? '重新分析' : '生成分析'}
        </button>
      </div>
      {report ? <Observation insight={report} /> : <p className="observation-empty" role="status">
        {pending[group] ? '正在读取分析…' : loadErrors[group] ? '暂时无法读取分析。' : tab.empty}
      </p>}
      {slot === 'weekly' && <SleepTrend points={report?.report?.trend} />}
      {generationErrors[slot] && <p className="observation-error" role="alert">{generationErrors[slot]}</p>}
    </div>

    <details className="observation-archive" onToggle={event => setArchiveOpen(event.currentTarget.open)}>
      <summary>历史分析</summary>
      {archiveOpen && (archiveError ? <p role="status">暂时无法读取历史分析。 <button type="button" className="observation-action"
        onClick={() => setArchiveAttempt(value => value + 1)}>重试</button></p>
        : archive === null ? <p role="status">正在读取历史分析…</p>
        : historical.length === 0 ? <p>暂无历史分析。</p>
        : <>
          {historical.slice(0, archiveLimit).map(item => <details key={`${item.time_slot}-${item.id}`} className="observation-archive-item">
            <summary>{item.date} · {archiveLabels[item.time_slot]}</summary>
            {item.report ? <Observation insight={item} /> : <p className="whitespace-pre-wrap">{item.content}</p>}
          </details>)}
          {historical.length > archiveLimit && <button type="button" className="observation-action"
            onClick={() => setArchiveLimit(value => value + 12)}>查看更多</button>}
        </>)}
    </details>
  </section>
}
