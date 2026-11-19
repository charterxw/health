import { useState, useEffect } from 'react'
import { getSleepHistory } from '../api/client'
import { MoonIcon } from './Icons'

function RichText({ text }) {
  return (
    <>
      {text.split('**').map((seg, i) =>
        i % 2 === 1 ? <strong key={i} className="font-semibold">{seg}</strong> : seg
      )}
    </>
  )
}

function SleepChart({ stages }) {
  if (!stages || stages.length === 0) return null;

  // We have 4 levels: Awake, REM, Light, Deep
  // We'll map them to Y coordinates 0, 1, 2, 3
  const levelY = {
    AWAKE: 0,
    REM: 1,
    LIGHT: 2,
    DEEP: 3,
  };

  const colors = {
    AWAKE: '#ff375f', // Pinkish
    REM: '#64d2ff', // Light Blue
    LIGHT: '#0a84ff', // Medium Blue
    DEEP: '#5e5ce6', // Dark Purple
  };

  const start = new Date(stages[0].startTime).getTime();
  const end = new Date(stages[stages.length - 1].endTime).getTime();
  const total = end - start;

  if (total <= 0) return null;

  const width = 1000;
  const height = 150;
  const ySpace = height / 4;

  const yPos = (stageName) => {
    return (levelY[stageName] !== undefined ? levelY[stageName] : 2) * ySpace + (ySpace / 2);
  };

  let pathData = '';
  stages.forEach((stage, i) => {
    const sTime = new Date(stage.startTime).getTime();
    const eTime = new Date(stage.endTime).getTime();
    
    const x1 = ((sTime - start) / total) * width;
    const x2 = ((eTime - start) / total) * width;
    const y = yPos(stage.stage);

    if (i === 0) {
      pathData += `M ${x1} ${y} `;
    } else {
      const prev = stages[i-1];
      const prevY = yPos(prev.stage);
      const prevX2 = ((new Date(prev.endTime).getTime() - start) / total) * width;
      // Draw vertical drop
      pathData += `L ${prevX2} ${prevY} L ${x1} ${y} `;
    }
    pathData += `L ${x2} ${y} `;
  });

  // Let's render the bars and lines. Actually the screenshot shows filled regions mapping to colors.
  // We will render SVG rects for the bars to give them the rounded pill look, and connect them with vertical lines.

  return (
    <div className="w-full overflow-hidden mt-4 mb-2">
      <svg viewBox={`0 0 ${width} ${height}`} className="w-full h-auto overflow-visible">
        {/* Background grid lines */}
        {[0, 1, 2, 3].map(i => (
          <rect key={i} x="0" y={i * ySpace + 10} width={width} height={ySpace - 20} rx={(ySpace - 20)/2} fill="rgba(100,100,100,0.05)" />
        ))}
        
        {/* Connectors */}
        <path d={pathData} fill="none" stroke="rgba(100,100,100,0.2)" strokeWidth="4" strokeLinejoin="round" />

        {/* Foreground rounded pills */}
        {stages.map((stage, i) => {
          const sTime = new Date(stage.startTime).getTime();
          const eTime = new Date(stage.endTime).getTime();
          const x1 = ((sTime - start) / total) * width;
          const x2 = ((eTime - start) / total) * width;
          const y = yPos(stage.stage);
          const color = colors[stage.stage] || colors.LIGHT;
          
          return (
            <rect 
              key={i}
              x={x1}
              y={y - (ySpace - 20)/2}
              width={Math.max(x2 - x1, 4)} // Ensure it's at least a small dot
              height={ySpace - 20}
              rx={(ySpace - 20)/2}
              fill={color}
            />
          )
        })}
      </svg>
      <div className="flex justify-between text-xs text-[var(--text-secondary)] mt-2 font-medium">
        <span>{new Date(start).toLocaleTimeString('zh-CN', { hour: 'numeric', minute: '2-digit' })}</span>
        <span>{new Date(end).toLocaleTimeString('zh-CN', { hour: 'numeric', minute: '2-digit' })}</span>
      </div>
    </div>
  );
}

function RecoveryMetric({ label, value, detail }) {
  return (
    <div className="rounded-xl bg-[var(--fill)] p-3 min-w-0">
      <p className="text-[10px] font-semibold uppercase tracking-wide text-[var(--text-secondary)]">{label}</p>
      <p className="text-[17px] font-bold tabular-nums mt-0.5">{value ?? '—'}</p>
      {detail && <p className="text-[10px] text-[var(--text-secondary)] mt-0.5 truncate">{detail}</p>}
    </div>
  )
}

function SleepCard({ sleep }) {
  const formatTime = (mins) => {
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return h > 0 ? `${h} 小时 ${m} 分` : `${m} 分钟`;
  };

  const sum = sleep.total_awake_mins + sleep.total_rem_mins + sleep.total_light_mins + sleep.total_deep_mins;
  const total = sleep.minutes_in_bed || sum;
  const h = Math.floor(total / 60);
  const m = total % 60;
  const timeInBed = `${h} 小时 ${m} 分`;

  const asleepTotal = sleep.minutes_asleep || (sleep.total_rem_mins + sleep.total_light_mins + sleep.total_deep_mins);
  const ah = Math.floor(asleepTotal / 60);
  const am = asleepTotal % 60;
  const timeAsleep = `${ah} 小时 ${am} 分`;

  // Fix timezone shift when parsing YYYY-MM-DD in JS by appending T12:00:00
  const dateStr = new Date(`${sleep.date}T12:00:00`).toLocaleDateString('zh-CN', { weekday: 'short', month: 'short', day: 'numeric' });
  const startObj = new Date(sleep.stages[0].startTime);
  const endObj = new Date(sleep.stages[sleep.stages.length - 1].endTime);
  const timeRange = `${startObj.toLocaleTimeString('zh-CN', {hour: 'numeric', minute:'2-digit'})} - ${endObj.toLocaleTimeString('zh-CN', {hour: 'numeric', minute:'2-digit'})}`;

  return (
    <div className="card p-5 mb-4">
      <div className="flex justify-between items-end mb-4">
        <div>
          <div className="flex items-center gap-2 mb-1">
            <h3 className="text-sm font-semibold text-[var(--text-secondary)]">{dateStr} ({timeRange})</h3>
            {sleep.is_nap && (
              <span className="px-1.5 py-0.5 text-[10px] uppercase font-bold tracking-wider bg-blue-500/10 text-blue-500 rounded">小睡</span>
            )}
          </div>
          <div className="text-2xl font-bold mt-1">睡眠 {timeAsleep}</div>
          <div className="text-sm font-medium text-[var(--text-secondary)] mt-1">卧床 {timeInBed}</div>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-y-2 text-sm mt-2">
        <div className="flex items-center gap-2">
          <span className="w-2.5 h-2.5 rounded-full bg-[#ff375f]" />
          <span className="font-medium">清醒 {formatTime(sleep.total_awake_mins)}</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="w-2.5 h-2.5 rounded-full bg-[#64d2ff]" />
          <span className="font-medium">快速眼动 {formatTime(sleep.total_rem_mins)}</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="w-2.5 h-2.5 rounded-full bg-[#0a84ff]" />
          <span className="font-medium">浅睡 {formatTime(sleep.total_light_mins)}</span>
        </div>
        <div className="flex items-center gap-2">
          <span className="w-2.5 h-2.5 rounded-full bg-[#5e5ce6]" />
          <span className="font-medium">深睡 {formatTime(sleep.total_deep_mins)}</span>
        </div>
      </div>

      {!sleep.is_nap && (
        <div className="mt-4 pt-4 border-t border-[var(--separator)]">
          <div className="flex items-center justify-between mb-2.5">
            <p className="text-[12px] font-semibold">恢复指标</p>
            <p className="text-[10px] text-[var(--text-secondary)]">与个人基线对比</p>
          </div>
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
            <RecoveryMetric
              label="睡眠效率"
              value={sleep.sleep_efficiency_percent != null ? `${sleep.sleep_efficiency_percent}%` : null}
              detail="睡眠时间 ÷ 卧床时间"
            />
            <RecoveryMetric
              label="平均血氧"
              value={sleep.spo2_average != null ? `${sleep.spo2_average}%` : null}
              detail={sleep.spo2_lower_bound != null && sleep.spo2_upper_bound != null
                ? `${sleep.spo2_lower_bound}–${sleep.spo2_upper_bound}% 区间`
                : null}
            />
            <RecoveryMetric
              label="呼吸频率"
              value={sleep.respiratory_rate != null ? `${sleep.respiratory_rate}` : null}
              detail={sleep.respiratory_rate != null ? '次/分钟' : null}
            />
            <RecoveryMetric
              label="腕部皮温"
              value={sleep.skin_temperature_delta_c != null
                ? `${sleep.skin_temperature_delta_c > 0 ? '+' : ''}${sleep.skin_temperature_delta_c}°C`
                : null}
              detail="相对个人基线"
            />
            <RecoveryMetric
              label="入睡用时"
              value={sleep.sleep_latency_minutes != null ? `${sleep.sleep_latency_minutes} 分钟` : null}
              detail="自动识别的记录可能显示为 0"
            />
            <RecoveryMetric
              label="清醒次数"
              value={sleep.awake_periods != null ? `${sleep.awake_periods}` : null}
              detail={sleep.short_awakenings ? `${sleep.short_awakenings} 次短暂清醒` : '清醒阶段次数'}
            />
          </div>
          <p className="text-[10px] leading-relaxed text-[var(--text-secondary)] mt-2.5">
            血氧、呼吸和腕部皮温用于了解健康趋势，不能作为诊断依据。
          </p>
        </div>
      )}

      <SleepChart stages={sleep.stages} />
    </div>
  );
}

export default function SleepTab() {
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const controller = new AbortController()
    getSleepHistory(14, controller.signal).then(data => {
      if (!controller.signal.aborted) setHistory(data || [])
    }).catch(error => {
      if (!controller.signal.aborted) console.error(error)
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false)
    })
    return () => controller.abort()
  }, []);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <div className="w-7 h-7 border-2 border-[var(--text-secondary)] border-t-transparent rounded-full animate-spin" />
      </div>
    );
  }

  if (history.length === 0) {
    return (
      <div className="text-center py-16 text-[var(--text-secondary)] flex flex-col items-center">
        <MoonIcon className="w-12 h-12 mb-4 opacity-50" />
        暂无详细睡眠记录。
      </div>
    );
  }

  return (
    <div className="rise pb-8">
      <h3 className="text-xl font-bold tracking-tight mb-4 ml-1">近期睡眠</h3>
      
      {history.map((sleep, i) => (
        <SleepCard key={i} sleep={sleep} />
      ))}
    </div>
  );
}
