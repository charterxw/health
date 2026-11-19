import HealthIcon from './HealthIcon'

export const pages = [
  { id: 'dashboard', label: '总览', description: '日常活动与恢复' },
  { id: 'strength', label: '训练', description: '力量训练记录' },
  { id: 'workout', label: '运动记录', description: '已完成的运动与训练' },
  { id: 'sleep', label: '睡眠', description: '睡眠与恢复' },
]

export default function Navigation({ activeTab, setActiveTab }) {
  return <nav className="health-navigation" aria-label="主要页面">
    {pages.map(page => <button
      key={page.id}
      className={`health-nav-item ${activeTab === page.id ? 'active' : ''}`}
      aria-current={activeTab === page.id ? 'page' : undefined}
      onClick={() => setActiveTab(page.id)}
    ><HealthIcon name={page.id} /><span>{page.label}</span></button>)}
  </nav>
}
