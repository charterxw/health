import useWorkoutPhysiology from '../training/useWorkoutPhysiology'
import '../training/physiology.css'

export const GOOGLE_HEALTH_APP_URL = 'https://www.fitbit.com/in-app/today'
const labels = {
  pending: '正在获取训练数据', not_requested: '尚未获取', waiting_sync: '等待设备数据同步',
  partial: '部分心率数据已到达', ready: '已获取训练时段数据', needs_source: '请选择心率来源',
  connection_required: '需要检查 Google Health 授权', error: '云端数据暂时无法获取',
  unavailable: '未获取到这段时间的心率', unsupported: '这场训练的时长不支持自动获取',
}
const number = value => value == null ? '—' : Number(value).toLocaleString('zh-CN', { maximumFractionDigits: 1 })
function timeLabel(value, timezone, seconds = false) {
  return new Intl.DateTimeFormat('zh-CN', { hour: '2-digit', minute: '2-digit',
    ...(seconds ? { second: '2-digit' } : {}), hour12: false, timeZone: timezone }).format(new Date(value))
}

export function HeartChart({ chart, timezone, marks = [], endedAt }) {
  const values = chart.filter(p => p.mean_bpm != null).map(p => p.mean_bpm)
  if (!values.length) return null
  const low = Math.floor((Math.min(...values) - 5) / 10) * 10
  const high = Math.max(low + 20, Math.ceil((Math.max(...values) + 5) / 10) * 10)
  const start = Date.parse(chart[0].at)
  const end = Math.max(Date.parse(chart.at(-1).at), Date.parse(endedAt) || start)
  const x = stamp => end > start ? 32 + (stamp - start) / (end - start) * 300 : 182
  const y = value => 109 - (value - low) / (high - low) * 92
  const points = marks.map(mark => ({ ...mark, stamp: Date.parse(mark.at) }))
    .filter(mark => mark.stamp >= start && mark.stamp <= end).sort((a, b) => a.stamp - b.stamp)
  const labels = []
  for (const point of points) {
    if (point.opening) continue
    const position = x(point.stamp)
    const label = timeLabel(point.at, timezone)
    if (!labels.length || (position - labels.at(-1).position >= 30 && label !== labels.at(-1).label)) {
      labels.push({ id: point.id, position, label })
    }
  }
  const segments = []
  let current = []
  chart.forEach(point => {
    if (point.mean_bpm == null) { if (current.length) segments.push(current); current = [] }
    else current.push([x(Date.parse(point.at)), y(point.mean_bpm)])
  })
  if (current.length) segments.push(current)
  return <figure className="st-heart-chart">
      <svg viewBox={points.length ? '0 0 340 151' : '0 0 340 142'} role="img"
        aria-label={points.length ? '训练心率曲线，按训练起点和后续动作的首组记录定位' : '训练心率曲线，每分钟平均心率，缺失分钟留空'}>
        {[low, high].map(value => <g key={value}><line x1="32" x2="332" y1={y(value)} y2={y(value)} className="st-heart-grid" /><text x="25" y={y(value) + 3} textAnchor="end">{value}</text></g>)}
        {points.filter(point => !point.opening).map(point => <g key={point.id}>
          <line x1={x(point.stamp)} x2={x(point.stamp)} y1="17" y2="114" className="st-heart-set-line" />
          <circle cx={x(point.stamp)} cy="114" r="2.4" className="st-heart-set-dot" />
        </g>)}
        {segments.map((segment, i) => segment.length === 1
          ? <circle key={i} cx={segment[0][0]} cy={segment[0][1]} r="2.5" className="st-heart-point" />
          : <polyline key={i} points={segment.map(p => p.join(',')).join(' ')} className="st-heart-line" />)}
        {labels.map(label => <text key={label.id} x={label.position} y="127" textAnchor="middle">{label.label}</text>)}
        <text x="32" y={points.length ? 144 : 135}>{timeLabel(chart[0].at, timezone)}</text>
        <text x="332" y={points.length ? 144 : 135} textAnchor="end">{timeLabel(endedAt || chart.at(-1).at, timezone)}</text>
      </svg>
    {points.length > 0 && <ul className="st-heart-splits" aria-label="动作时间定位">
      {points.map(point => <li key={point.id}>
        <div><time dateTime={point.at}>{timeLabel(point.at, timezone, true)}</time><strong>{point.name}</strong></div>
        <p>{point.opening ? '训练起点' : '首组记录'}</p>
      </li>)}
    </ul>}
  </figure>
}

export function PhysiologyView({ data, error = '', busy = false, serverSaved = true, timezone, marks, endedAt, onRefresh, onSelectSource, onOpenHealth }) {
  const heart = data?.heart_rate
  const stats = heart?.summary
  const hasHeart = stats?.sample_count > 0
  const energy = data?.metrics?.active_energy?.value
  // attempts/checked_at advance when a server worker starts, before Google
  // responds. Only a stored outcome proves that automatic collection finished.
  const hasCollectionResult = Boolean(heart?.fetched_at || Object.keys(data?.errors || {}).length)
  const showSyncLink = serverSaved && hasCollectionResult && ['waiting_sync', 'partial', 'unavailable', 'error'].includes(data?.status)
  const status = !serverSaved ? '训练保存到服务器后会自动获取。'
    : error || (data?.syncing && !hasCollectionResult ? '正在自动获取训练数据…'
      : busy && !data ? '正在读取训练数据…' : labels[data?.status] || '正在准备训练数据')
  const glance = hasHeart && !error && data.status !== 'partial'
  return <details className="st-physiology" aria-label="训练时段健康数据">
    <summary className="st-report-disclosure">
      <span className="st-physiology-overview">
        <strong>心率与活动</strong>
        <span role="status" className={glance ? 'st-physiology-glance' : undefined}>{glance
          ? `平均 ${number(stats.mean_bpm)} · 最高 ${number(stats.max_bpm)} 次/分`
          : hasHeart && data.status === 'partial' && !error ? '部分心率数据' : status}</span>
      </span>
    </summary>
    <div className="st-physiology-body">
      {showSyncLink && <div className="st-open-health">
        <a href={GOOGLE_HEALTH_APP_URL} target="_blank" rel="noopener noreferrer" onClick={onOpenHealth}>打开 Google Health 同步 <span aria-hidden="true">↗</span></a>
      </div>}
      {heart?.sources.length > 1 && <label className="st-heart-source">心率来源
        <select aria-label="心率来源" value={heart.selected_source?.id || ''} disabled={busy} onChange={e => onSelectSource(e.target.value)}>
          <option value="" disabled>选择本次佩戴的设备</option>
          {heart.sources.map((source, i) => <option key={source.id} value={source.id}>{source.label || '穿戴设备'}{heart.sources.filter(s => s.label === source.label).length > 1 ? ` ${i + 1}` : ''}</option>)}
        </select>
      </label>}
      {(hasHeart || energy != null) && <dl className="st-heart-metrics">
        {hasHeart && <>
          <div><dt>平均心率</dt><dd>{number(stats.mean_bpm)}<small> 次/分</small></dd></div>
          <div><dt>最高心率</dt><dd>{number(stats.max_bpm)}<small> 次/分</small></dd></div>
          <div><dt>最低心率</dt><dd>{number(stats.min_bpm)}<small> 次/分</small></dd></div>
        </>}
        <div><dt>估算活动热量</dt><dd>{number(energy)}<small> 千卡</small></dd></div>
      </dl>}
      {hasHeart && <HeartChart chart={heart.chart} timezone={timezone} marks={marks} endedAt={endedAt || data.ended_at} />}
      <footer>
        <span>Google Health</span>
        <button type="button" disabled={!serverSaved || busy || data?.syncing || data?.status === 'unsupported'} onClick={onRefresh}>{busy || data?.syncing ? '获取中…' : '重新获取'}</button>
      </footer>
    </div>
  </details>
}

export default function WorkoutPhysiology({ session, marks, serverSaved, visible }) {
  const { data, error, busy, refresh, selectSource, openGoogleHealth } = useWorkoutPhysiology(session, serverSaved, visible)
  return <PhysiologyView data={data} error={error} busy={busy} serverSaved={serverSaved} timezone={session.timezone}
    marks={marks} endedAt={session.ended_at} onRefresh={refresh} onSelectSource={selectSource} onOpenHealth={openGoogleHealth} />
}
