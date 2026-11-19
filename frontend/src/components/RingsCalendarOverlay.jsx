import { useState, useEffect, useRef } from 'react'
import { getHealthHistory } from '../api/client'
import ActivityRings from './ActivityRings'
import Modal from './Modal'

const GOALS = { move: 500, exercise: 60, steps: 8000 }

export default function RingsCalendarOverlay({ onClose }) {
  const [history, setHistory] = useState([])
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [attempt, setAttempt] = useState(0)
  const [tooltip, setTooltip] = useState(null)
  const scrollRef = useRef(null)

  useEffect(() => {
    const controller = new AbortController()
    setLoading(true)
    setFailed(false)
    getHealthHistory(90, controller.signal).then(data => {
      if (!controller.signal.aborted) setHistory(data)
    }).catch(() => {
      if (!controller.signal.aborted) setFailed(true)
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false)
    })
    return () => controller.abort()
  }, [attempt])

  useEffect(() => {
    if (!loading && scrollRef.current) {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight
    }
  }, [loading])

  // Group days by month
  function getMonths() {
    if (!history.length) return []
    const sorted = [...history].sort((a, b) => a.date.localeCompare(b.date))
    const months = {}
    for (const day of sorted) {
      const key = day.date.slice(0, 7)
      if (!months[key]) months[key] = []
      months[key].push(day)
    }
    // Return oldest first (so newest is at bottom)
    return Object.entries(months)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([key, days]) => {
        const [y, m] = key.split('-').map(Number)
        const label = new Date(y, m - 1, 15).toLocaleDateString('zh-CN', { month: 'long', year: 'numeric' })
        return { label, days, key }
      })
  }

  function getWeeksForMonth(days) {
    if (!days.length) return []
    const [y, m, d] = days[0].date.split('-').map(Number)
    const firstDate = new Date(y, m - 1, d)
    // Monday = 0, Sunday = 6
    let dow = (firstDate.getDay() + 6) % 7
    const padded = [...Array(dow).fill(null), ...days]
    const weeks = []
    for (let i = 0; i < padded.length; i += 7) {
      weeks.push(padded.slice(i, i + 7))
    }
    // Pad last week
    const last = weeks[weeks.length - 1]
    while (last.length < 7) last.push(null)
    return weeks
  }

  function handleDayClick(day) {
    if (tooltip?.date === day.date) {
      setTooltip(null)
    } else {
      setTooltip(day)
    }
  }

  const months = getMonths()
  const dayLabels = ['一', '二', '三', '四', '五', '六', '日']

  return (
    <Modal title="活动日历" onClose={onClose} centered>

        {/* Tooltip */}
        {tooltip && (
          <div className="card px-4 py-3 mb-3 shrink-0 border border-[var(--card-border)]">
            <p className="text-[12px] font-semibold text-[var(--text-secondary)] mb-1.5">
              {(() => { const [y,m,d] = tooltip.date.split('-').map(Number); return new Date(y, m-1, d).toLocaleDateString('zh-CN', { weekday: 'long', month: 'short', day: 'numeric' }) })()}
            </p>
            <div className="flex gap-4 text-[13px]">
              <div>
                <span className="inline-block w-2 h-2 rounded-full bg-[#ff375f] mr-1" />
                <span className="font-semibold">{(tooltip.calories_burned || 0).toLocaleString()}</span>
                <span className="text-[var(--text-secondary)]"> 千卡</span>
              </div>
              <div>
                <span className="inline-block w-2 h-2 rounded-full bg-[#34c759] mr-1" />
                <span className="font-semibold">{tooltip.active_minutes || 0}</span>
                <span className="text-[var(--text-secondary)]"> 分钟</span>
              </div>
              <div>
                <span className="inline-block w-2 h-2 rounded-full bg-[#007aff] mr-1" />
                <span className="font-semibold">{(tooltip.steps || 0).toLocaleString()}</span>
                <span className="text-[var(--text-secondary)]"> 步</span>
              </div>
            </div>
          </div>
        )}

        {loading ? (
          <p className="overview-detail-status" role="status">正在读取活动记录…</p>
        ) : failed ? (
          <div className="overview-detail-status"><span role="status">暂时无法读取记录</span>
            <button type="button" onClick={() => setAttempt(value => value + 1)}>重试</button>
          </div>
        ) : !months.length ? (
          <p className="overview-detail-status" role="status">这段时间没有记录</p>
        ) : (
          <div className="overview-calendar" ref={scrollRef}>
            {months.map(({ label, days, key }) => {
              const weeks = getWeeksForMonth(days)
              return (
                <div key={key} className="mb-5">
                  <p className="text-[13px] font-semibold text-[var(--text-secondary)] mb-2">{label}</p>

                  {/* Day labels */}
                  <div className="grid grid-cols-7 gap-1.5 mb-1">
                    {dayLabels.map((d, i) => (
                      <span key={i} className="text-center text-[9px] font-medium text-[var(--text-secondary)]">{d}</span>
                    ))}
                  </div>

                  {/* Weeks */}
                  {weeks.map((week, wi) => (
                    <div key={wi} className="grid grid-cols-7 gap-1.5 mb-1.5">
                      {week.map((day, di) => {
                        if (!day) return <div key={di} />
                        const rings = [
                          { id: 'move', value: day.calories_burned || 0, goal: GOALS.move, from: '#ff2d55', to: '#ff6482' },
                          { id: 'exercise', value: day.active_minutes || 0, goal: GOALS.exercise, from: '#34c759', to: '#69f0ae' },
                          { id: 'steps', value: day.steps || 0, goal: GOALS.steps, from: '#007aff', to: '#64d2ff' },
                        ]
                        const dateNum = parseInt(day.date.split('-')[2], 10)
                        const isSelected = tooltip?.date === day.date
                        return (
                          <button
                            key={di}
                            type="button"
                            aria-label={day.date}
                            aria-pressed={isSelected}
                            className={`flex flex-col items-center min-h-11 min-w-0 gap-0.5 rounded-lg py-0.5 ${isSelected ? 'bg-[var(--fill)]' : ''}`}
                            onClick={() => handleDayClick(day)}
                          >
                            <ActivityRings rings={rings} className="w-full max-w-9 h-auto" />
                            <span className="text-[9px] tabular-nums text-[var(--text-secondary)]">{dateNum}</span>
                          </button>
                        )
                      })}
                    </div>
                  ))}
                </div>
              )
            })}
          </div>
        )}

        {/* Legend */}
        <div className="flex items-center justify-center gap-4 mt-3 pt-3 border-t border-[var(--separator)] shrink-0">
          <div className="flex items-center gap-1.5">
            <span className="w-2 h-2 rounded-full bg-[#ff375f]" />
            <span className="text-[10px] text-[var(--text-secondary)]">活动热量</span>
          </div>
          <div className="flex items-center gap-1.5">
            <span className="w-2 h-2 rounded-full bg-[#34c759]" />
            <span className="text-[10px] text-[var(--text-secondary)]">运动时长</span>
          </div>
          <div className="flex items-center gap-1.5">
            <span className="w-2 h-2 rounded-full bg-[#007aff]" />
            <span className="text-[10px] text-[var(--text-secondary)]">步数</span>
          </div>
        </div>
    </Modal>
  )
}
