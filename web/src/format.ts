export function formatCost(usd: number): string {
  if (usd >= 100) return `$${Math.round(usd)}`
  return `$${usd.toFixed(2)}`
}

function sameDay(left: Date, right: Date): boolean {
  return left.getFullYear() === right.getFullYear() && left.getMonth() === right.getMonth() && left.getDate() === right.getDate()
}

export function clockTime(date: Date): string {
  return `${date.getHours()}:${String(date.getMinutes()).padStart(2, '0')}`
}

export function shortTime(date: Date, now = new Date()): string {
  if (sameDay(date, now)) return clockTime(date)
  const yesterday = new Date(now)
  yesterday.setDate(now.getDate() - 1)
  if (sameDay(date, yesterday)) return 'Yesterday'
  return date.toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })
}

export function elapsed(since: Date, now = new Date()): string {
  const minutes = Math.max(0, Math.round((now.getTime() - since.getTime()) / 60000))
  if (minutes < 60) return `${minutes} min`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours} h ${minutes % 60} min`
  return `${Math.floor(hours / 24)} d`
}

export function duration(seconds: number): string {
  if (seconds < 60) return `${Math.round(seconds)}s`
  return `${Math.floor(seconds / 60)}m ${Math.round(seconds % 60)}s`
}

const MODELS: Record<string, string> = { opus: 'Opus', sonnet: 'Sonnet', haiku: 'Haiku', fable: 'Fable' }

export function modelTitle(model: string | null | undefined): string {
  if (!model) return 'Opus'
  const lower = model.toLowerCase()
  const known = Object.keys(MODELS).find((key) => lower.includes(key))
  return known ? MODELS[known] : model
}

export function effortTitle(effort: string | null | undefined): string {
  if (!effort) return 'Medium'
  return effort.charAt(0).toUpperCase() + effort.slice(1)
}

export function workflowTitle(workflow: string | null | undefined): string {
  if (!workflow) return 'Lead picks the workflow'
  return workflow.replace(/[-_]+/g, ' ').replace(/^\w/, (letter) => letter.toUpperCase())
}

export function hostTitle(host: string | null): string {
  if (!host) return 'This Mac'
  return `SSH · ${host}`
}

export function plural(count: number, word: string): string {
  return `${count} ${word}${count === 1 ? '' : 's'}`
}
