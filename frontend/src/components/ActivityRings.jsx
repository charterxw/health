import { useId } from 'react'

// Apple Fitness–style concentric activity rings, drawn with SVG.
// Each ring is a { value, goal, colors:[from,to], track } definition.

const SIZE = 200
const CENTER = SIZE / 2
const STROKE = 20
const GAP = 6

function Ring({ index, value, goal, from, to, id }) {
  const radius = CENTER - STROKE / 2 - index * (STROKE + GAP)
  const circ = 2 * Math.PI * radius
  const pct = Math.max(0, Math.min((value ?? 0) / goal, 1))
  const offset = circ * (1 - pct)

  return (
    <>
      {/* track */}
      <circle
        cx={CENTER}
        cy={CENTER}
        r={radius}
        fill="none"
        stroke={from}
        strokeOpacity="0.18"
        strokeWidth={STROKE}
      />
      {/* progress */}
      {pct > 0 && <circle
        cx={CENTER}
        cy={CENTER}
        r={radius}
        fill="none"
        stroke={`url(#grad-${id})`}
        strokeWidth={STROKE}
        strokeLinecap="round"
        strokeDasharray={circ}
        className="ring-progress"
        style={{ '--dash-start': circ, '--dash-end': offset, animationDelay: `${index * 0.12}s` }}
      />}
      <defs>
        <linearGradient id={`grad-${id}`} x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stopColor={to} />
          <stop offset="100%" stopColor={from} />
        </linearGradient>
      </defs>
    </>
  )
}

export default function ActivityRings({ rings, className = 'w-[150px] h-[150px] sm:w-[168px] sm:h-[168px]' }) {
  const prefix = useId().replace(/:/g, '')
  return (
    <svg viewBox={`0 0 ${SIZE} ${SIZE}`} className={`shrink-0 ${className}`}>
      {rings.map((r, i) => (
        <Ring key={r.id} index={i} {...r} id={`${prefix}-${r.id}`} />
      ))}
    </svg>
  )
}
