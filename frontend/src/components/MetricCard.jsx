export default function MetricCard({ title, value, unit, chip, icon, className = '' }) {
  return (
    <div className={`card p-4 flex flex-col justify-between ${className}`}>
      <div className="flex items-center justify-between gap-2">
        <span className="text-[13px] font-semibold text-[var(--text-secondary)] truncate">{title}</span>
        <span className={`icon-chip shrink-0 ${chip}`}>{icon}</span>
      </div>
      <div className="mt-3">
        <div className="flex items-baseline gap-1.5">
          <span className="text-[28px] font-bold tracking-tight tabular-nums leading-none">{value}</span>
          {unit && <span className="text-sm font-medium text-[var(--text-secondary)]">{unit}</span>}
        </div>
      </div>
    </div>
  )
}
