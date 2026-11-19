// Minimal SF Symbols–style line icons. All inherit currentColor / size via props.
const base = {
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 2,
  strokeLinecap: 'round',
  strokeLinejoin: 'round',
}

function Svg({ children, size = 18 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" {...base}>
      {children}
    </svg>
  )
}

export const FootstepsIcon = (p) => (
  <Svg {...p}>
    <path d="M7 4c1.7 0 2.5 1.8 2.5 4S9 14 7 14s-2.5-1.6-2.5-4S5.3 4 7 4Z" fill="currentColor" stroke="none" />
    <path d="M6.2 14.5c1.4 0 2.3.8 2.3 2.2 0 1.1-.6 2.3-2 2.3s-2.2-1-2.2-2.3c0-1.2.5-2.2 1.9-2.2Z" fill="currentColor" stroke="none" />
    <path d="M17 6c1.7 0 2.5 1.8 2.5 4S19 16 17 16s-2.5-1.6-2.5-4S15.3 6 17 6Z" fill="currentColor" stroke="none" opacity="0.55" />
  </Svg>
)

export const MoonIcon = (p) => (
  <Svg {...p}>
    <path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5Z" fill="currentColor" stroke="none" />
  </Svg>
)

export const FlameIcon = (p) => (
  <Svg {...p}>
    <path d="M12 3s5 3.5 5 8.5A5 5 0 0 1 7 12c0-1.6.7-2.8 1.4-3.6.2 1 .8 1.6 1.6 1.8C10.4 8 9.5 5.6 12 3Z" fill="currentColor" stroke="none" />
  </Svg>
)

export const BoltIcon = (p) => (
  <Svg {...p}>
    <path d="M13 3 5 13h5l-1 8 8-10h-5l1-8Z" fill="currentColor" stroke="none" />
  </Svg>
)

export const HeartIcon = (p) => (
  <Svg {...p}>
    <path d="M12 20s-7-4.4-9.2-8.3C1.2 8.6 2.6 5 6 5c2 0 3.2 1.2 4 2.3C10.8 6.2 12 5 14 5c3.4 0 4.8 3.6 3.2 6.7C19 15.6 12 20 12 20Z" fill="currentColor" stroke="none" />
  </Svg>
)

export const PulseIcon = (p) => (
  <Svg {...p}>
    <path d="M3 12h4l2-6 4 12 2-6h6" />
  </Svg>
)

export const RunIcon = (p) => (
  <Svg {...p}>
    <circle cx="15" cy="4.5" r="2" fill="currentColor" stroke="none" />
    <path d="M4 14l3-1 2.5-3 3 1.5L14 15m-4-2-1 6m4-4 3 3" />
  </Svg>
)

export const SparkleIcon = (p) => (
  <Svg {...p}>
    <path d="M12 3l1.6 4.9L18.5 9.5 13.6 11 12 16l-1.6-5L5.5 9.5l4.9-1.6L12 3Z" fill="currentColor" stroke="none" />
    <path d="M18.5 15l.7 2.1L21.5 18l-2.3.9-.7 2.1-.7-2.1L15.5 18l2.3-.9.7-2.1Z" fill="currentColor" stroke="none" opacity="0.7" />
  </Svg>
)

export const SunIcon = (p) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="4" fill="currentColor" stroke="none" />
    <path d="M12 2v2m0 16v2M2 12h2m16 0h2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4" />
  </Svg>
)

export const DistanceIcon = (p) => (
  <Svg {...p}>
    <path d="M3 20L7.5 4l5 12L17 8l4 12" />
  </Svg>
)

export const SunriseIcon = (p) => (
  <Svg {...p}>
    <path d="M3 18h18M12 3v6m-3-2 3-3 3 3" />
    <path d="M6 14a6 6 0 0 1 12 0" />
  </Svg>
)
