import type { ReactNode } from 'react'
import type { AgentKind } from './records'

export type Face = 'lead' | 'back' | 'front' | 'cli' | 'review'

const FACE_COLORS: Record<Face, [string, string]> = {
  lead: ['#8E5BEA', '#E7D6FF'], back: ['#26A866', '#C9F7DD'], front: ['#2F97CF', '#D3F2FF'], cli: ['#CF6E50', '#FFE0D3'], review: ['#E0952A', '#FFEBC8'],
}

const FACE_GLYPHS: Record<Face, string> = {
  lead: 'M-3.6 1.8L0-1.8L3.6 1.8', back: 'M-2.6-2.6h5.2v5.2h-5.2z', front: 'M-2.8 0a2.8 2.8 0 1 0 5.6 0a2.8 2.8 0 1 0-5.6 0',
  cli: 'M-1-2.6L-3.4 0L-1 2.6M1-2.6L3.4 0L1 2.6', review: 'M-3 .2L-1 2.2L3-2',
}

function hash(text: string): number {
  let value = 0
  for (const character of text) value = (value * 31 + character.charCodeAt(0)) >>> 0
  return value
}

export function faceFor(kind: AgentKind, name = ''): Face {
  if (kind === 'lead') return 'lead'
  if (kind === 'checker') return 'review'
  const lower = name.toLowerCase()
  if (/front|react|ui|web|swift/.test(lower)) return 'front'
  if (/back|api|django|server|data/.test(lower)) return 'back'
  if (/cli|claude|shell/.test(lower)) return 'cli'
  return (['front', 'back', 'cli'] as const)[hash(name) % 3]
}

export function Avatar({ kind, name, size = 26, busy = false }: { kind: AgentKind; name?: string; size?: number; busy?: boolean }) {
  const face = faceFor(kind, name)
  const [color, light] = FACE_COLORS[face]
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-hidden="true" className="avatar">
      <rect x="5" y="6" width="54" height="52" rx="15" fill={color} />
      <rect x="5" y="6" width="54" height="52" rx="15" fill="url(#v6shine)" />
      <rect x="11" y="12" width="42" height="30" rx="8" fill="#0b1318" />
      <g transform={`translate(${busy ? 2 : 0} 0)`}>
        <rect x="21.5" y="22.5" width="5" height="7" rx="2.5" fill={light} />
        <rect x="37.5" y="22.5" width="5" height="7" rx="2.5" fill={light} />
      </g>
      <path d="M28 34.5h8" stroke={light} strokeWidth="2" strokeLinecap="round" opacity="0.7" />
      <path transform="translate(32 50)" d={FACE_GLYPHS[face]} fill="none" stroke="#fff" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

export function AvatarDefs() {
  return (
    <svg width="0" height="0" aria-hidden="true" style={{ position: 'absolute' }}>
      <defs>
        <linearGradient id="v6shine" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#fff" stopOpacity="0.28" />
          <stop offset="0.6" stopColor="#fff" stopOpacity="0" />
        </linearGradient>
      </defs>
    </svg>
  )
}

const TILE_COLORS = ['#2E9E5B', '#2B7FD9', '#7B5BEA', '#CF6E50', '#E0952A', '#2F97CF']

export function tileColor(name: string): string {
  return TILE_COLORS[hash(name) % TILE_COLORS.length]
}

export function ProjectTile({ name, size = 14 }: { name: string; size?: number }) {
  return (
    <span aria-hidden="true" className="tile" style={{ width: size, height: size, background: tileColor(name), fontSize: size * 0.6, borderRadius: size * 0.28 }}>
      {name.charAt(0).toUpperCase()}
    </span>
  )
}

export const ICONS = {
  menu: 'M4 7h16M4 12h16M4 17h16',
  details: 'M4 5h16v14H4zM15 5v14',
  attach: 'M8 12.5l5.6-5.6a3 3 0 0 1 4.2 4.2L11 18a5 5 0 0 1-7-7l6.4-6.4',
  send: 'M12 19V5M6 11l6-6 6 6',
  workflow: 'M6 4h5v5H6zM13 15h5v5h-5zM8.5 9v3a2 2 0 0 0 2 2h3a2 2 0 0 1 2 2',
  plus: 'M12 5v14M5 12h14',
  close: 'M6 6l12 12M18 6L6 18',
  search: 'M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14M20 20l-4-4',
  chevronDown: 'M6 9l6 6 6-6',
  chevronRight: 'M9 6l6 6-6 6',
  back: 'M15 6l-6 6 6 6',
  task: 'M9 4h6v3H9zM7 5.5H5.5V20h13V5.5H17M9 13.5l2 2 4-4.5',
  project: 'M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z',
  log: 'M4.5 6h.01M4.5 12h.01M4.5 18h.01M8.5 6H20M8.5 12H20M8.5 18H20',
  branch: 'M7 4v12M7 16a2 2 0 1 0 0 4a2 2 0 1 0 0-4M17 6a2 2 0 1 0 0 4a2 2 0 1 0 0-4M17 10c0 4-4 4-10 6',
  terminal: 'M4 5h16v14H4zM8 10l2.5 2L8 14M12.5 14H16',
  check: 'M5 12.5l4.5 4.5L19 7.5',
  cross: 'M7 7l10 10M17 7L7 17',
  external: 'M14 4h6v6M20 4l-9 9M18 14v5H5V6h5',
}

export function Icon({ name, size = 20, stroke = 1.8 }: { name: keyof typeof ICONS; size?: number; stroke?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className="icon">
      <path d={ICONS[name]} />
    </svg>
  )
}

export function IconButton({ label, icon, onClick, children, expanded, className = '' }: {
  label: string; icon: keyof typeof ICONS; onClick?: () => void; children?: ReactNode; expanded?: boolean; className?: string
}) {
  return (
    <button type="button" className={`icon-button ${className}`} aria-label={label} aria-expanded={expanded} onClick={onClick}>
      <Icon name={icon} size={icon === 'close' ? 20 : 22} />
      {children}
    </button>
  )
}

export function Dots() {
  return (
    <span aria-hidden="true">
      <span className="dot-blink">•</span><span className="dot-blink d2">•</span><span className="dot-blink d3">•</span>
    </span>
  )
}

export function StatusDot({ tone, label, pulse = false }: { tone: string; label: string; pulse?: boolean }) {
  return (
    <span role="img" aria-label={label} className="status-dot">
      {pulse && <span className={`pulse bg-${tone}`} aria-hidden="true" />}
      <span className={`core fill-${tone}`} aria-hidden="true" />
    </span>
  )
}
