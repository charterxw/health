export default function HealthIcon({ name = 'health', size = 22, ...props }) {
  const icons = {
    arrow: <path d="m9 5 7 7-7 7" />,
    health: <><path d="M20.8 4.9a5.3 5.3 0 0 0-7.5 0L12 6.2l-1.3-1.3a5.3 5.3 0 0 0-7.5 7.5L12 21l8.8-8.6a5.3 5.3 0 0 0 0-7.5Z" /><path d="M3 12h4l2-4 4 8 2-4h6" /></>,
    dashboard: <><rect x="3" y="3" width="7" height="7" rx="2" /><rect x="14" y="3" width="7" height="7" rx="2" /><rect x="3" y="14" width="7" height="7" rx="2" /><rect x="14" y="14" width="7" height="7" rx="2" /></>,
    strength: <><path d="m6 6 12 12M3 9l6-6m6 18 6-6M2 6l4-4m12 20 4-4M5 12l7-7m0 14 7-7" /></>,
    workout: <><path d="M8 5H6a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2" /><rect x="8" y="2" width="8" height="5" rx="2" /><path d="m8 13 2 2 5-5M8 19h8" /></>,
    calendar: <><rect x="3" y="5" width="18" height="16" rx="3" /><path d="M7 3v4m10-4v4M3 10h18" /></>,
    sleep: <path d="M20.5 13.2A8.7 8.7 0 0 1 10.8 3a9 9 0 1 0 9.7 10.2Z" />,
    refresh: <path d="M20 11a8 8 0 1 0-2.3 6M20 5v6h-6" />,
    logout: <><path d="M9 4H5a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h4M13 7l5 5-5 5M8 12h13" /></>,
    close: <path d="m6 6 12 12M6 18 18 6" />,
    trash: <><path d="M3 6h18m-16 0 1 14h12l1-14M9 6V3h6v3M10 10v6m4-6v6" /></>,
    settings: <><path d="m9 3-.8 2.1-2.1.4-1.7 2.9 1.3 1.8-.3 2.2-1.4 1.7 1.7 3 2.2.2 1.4 1.7.7 2.1h3.4l.7-2.1 1.4-1.7 2.2-.2 1.7-3-1.4-1.7-.3-2.2 1.3-1.8-1.7-2.9-2.1-.4L15 3Z" /><circle cx="12" cy="11.5" r="3" /></>,
  }
  return <svg className="health-icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" {...props}>{icons[name] || icons.health}</svg>
}
