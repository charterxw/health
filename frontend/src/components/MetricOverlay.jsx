import { useState, useEffect, useRef } from 'react'
import { getHealthHistory } from '../api/client'
import Modal from './Modal'

const VIEWS = ['近 7 天', '按周', '按月']
const parseLocalDate = (dateStr) => {
  const [year, month, day] = dateStr.split('-').map(Number)
  return new Date(year, month - 1, day || 1)
}
const averagePositive = (values) => {
  const valid = values.filter(value => Number.isFinite(value) && value > 0)
  return valid.length ? Math.round(valid.reduce((sum, value) => sum + value, 0) / valid.length) : 0
}

const compact = new Intl.NumberFormat('zh-CN', { notation: 'compact', maximumFractionDigits: 1 })

export default function MetricOverlay({ title, field, unit, gradient, recent, onRetry, onClose }) {
  const [view, setView] = useState(VIEWS[0])
  const [extended, setExtended] = useState(null)
  const extendedView = view !== VIEWS[0]
  const source = extendedView ? extended : recent
  const history = source?.data ?? []
  const loading = !source || source.status === 'loading'
  const scrollRef = useRef(null)

  useEffect(() => {
    if (!extendedView || extended) return
    const controller = new AbortController()
    getHealthHistory(365, controller.signal).then(data => {
      if (!controller.signal.aborted) setExtended({ data, status: 'ready' })
    }).catch(() => {
      if (!controller.signal.aborted) setExtended({ data: [], status: 'error' })
    })
    return () => controller.abort()
  }, [extendedView, extended])

  useEffect(() => {
    if (scrollRef.current) scrollRef.current.scrollLeft = scrollRef.current.scrollWidth
  }, [view, source])

  function getDisplayData() {
    if (!history.length) return []

    if (view === '近 7 天') {
      return history.slice(0, 7).reverse().map((d) => ({
        label: parseLocalDate(d.date).toLocaleDateString('zh-CN', { weekday: 'short' }),
        value: d[field],
        date: d.date,
      }))
    }

    if (view === '按周') {
      const weeks = []
      for (let i = 0; i < history.length; i += 7) {
        const chunk = history.slice(i, i + 7)
        if (chunk.length === 0) break
        const avg = averagePositive(chunk.map(d => d[field]))
        const startDate = chunk[chunk.length - 1].date
        const endDate = chunk[0].date
        weeks.push({
          label: `${fmtShort(startDate)}–${fmtShort(endDate)}`,
          value: avg,
          date: startDate,
        })
      }
      return weeks.reverse()
    }

    if (view === '按月') {
      const months = {}
      for (const d of history) {
        const key = d.date.slice(0, 7)
        if (!months[key]) months[key] = []
        months[key].push(d[field])
      }
      return Object.entries(months)
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([key, vals]) => ({
          label: parseLocalDate(key + '-01').toLocaleDateString('zh-CN', { month: 'short' }),
          value: averagePositive(vals),
          date: key,
        }))
    }

    return []
  }

  function fmtShort(dateStr) {
    return parseLocalDate(dateStr).toLocaleDateString('zh-CN', { month: 'short', day: 'numeric' })
  }

  const data = getDisplayData()
  const maxVal = Math.max(...data.map((d) => d.value ?? 0), 1)
  const avg = averagePositive(data.map(d => d.value))
  const retry = () => {
    if (!extendedView) return onRetry()
    setExtended(null)
  }

  return (
    <Modal title={title} onClose={onClose} centered>
        <div className="segmented flex mb-5">
          {VIEWS.map((v) => (
            <button
              key={v}
              data-active={view === v}
              aria-pressed={view === v}
              type="button"
              className="segmented-item flex-1 min-h-11 text-[13px] font-semibold text-center"
              onClick={() => setView(v)}
            >
              {v}
            </button>
          ))}
        </div>

        <div className="mb-4">
          <p className="text-[11px] font-semibold uppercase tracking-wide text-[var(--text-secondary)]">
            {view === '近 7 天' ? '日均' : view === '按周' ? '周均' : '月均'}
          </p>
          <p className="text-[32px] font-bold tabular-nums tracking-tight leading-none mt-1">
            {data.length ? avg.toLocaleString('zh-CN') : '—'}
            {!!data.length && <span className="text-sm font-medium text-[var(--text-secondary)] ml-1">{unit}</span>}
          </p>
        </div>

        {source?.status === 'error' && <div className="overview-detail-status">
          <span role="status">暂时无法读取记录</span><button type="button" onClick={retry}>重试</button>
        </div>}
        {data.length ? <div role="list" ref={scrollRef} className="overview-chart" tabIndex={extendedView ? 0 : undefined} aria-label={`${view}趋势`}>
          {data.map(day => <div role="listitem" className="overview-chart-point" key={day.date} aria-label={`${day.label} ${day.value ?? '无记录'} ${unit}`}>
            <span aria-hidden="true">{day.value == null ? '—' : compact.format(day.value)}</span>
            <div className="overview-chart-track" aria-hidden="true"><div style={{ height: `${(day.value ?? 0) / maxVal * 100}%`, background: gradient[0] }} /></div>
            <span aria-hidden="true">{day.label}</span>
          </div>)}
        </div> : source?.status !== 'error' && (
          <p className="overview-detail-status" role="status">{loading ? '正在读取记录…' : '这段时间没有记录'}</p>
        )}
    </Modal>
  )
}
