export function formatBytes(b: number | null | undefined): string {
  if (!b) return '-'
  if (b >= 1e9) return (b / 1e9).toFixed(1) + ' GB'
  if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB'
  if (b >= 1e3) return (b / 1e3).toFixed(0) + ' KB'
  return b + ' B'
}

/**
 * Format a host temperature. Missing sensors (`null` / `undefined` / NaN)
 * return null so the UI can show an em dash — never "0°C".
 * A real reading of 0 is formatted as "0°C".
 */
export function formatTemperatureC(celsius: number | null | undefined): string | null {
  if (celsius === null || celsius === undefined || Number.isNaN(celsius)) return null
  return `${Math.round(celsius)}°C`
}

export function pct(used: number, total: number): number {
  if (!total) return 0
  return Math.round((used / total) * 100)
}

export function formatMemoryMB(mb: number | null | undefined): string {
  if (mb == null || !Number.isFinite(mb)) return '—'
  if (mb >= 1024 && mb % 1024 === 0) return `${mb / 1024} GB`
  if (mb >= 1024) return `${(mb / 1024).toFixed(1)} GB`
  return `${Math.round(mb)} MB`
}

export function formatCores(n: number | null | undefined): string {
  if (n == null || !Number.isFinite(n)) return '—'
  return n === 1 ? '1 core' : `${n} cores`
}

export function formatPortForwards(
  rules: Array<{ protocol?: string; proto?: string; hostPort: number; guestPort: number }> | null | undefined,
): string {
  if (!rules?.length) return '—'
  return rules
    .map((rule) => `${(rule.protocol || rule.proto || 'tcp').toLowerCase()} ${rule.hostPort} → ${rule.guestPort}`)
    .join(', ')
}

export function parseLogDate(ts: string | number | null | undefined): Date | null {
  if (ts == null || ts === '') return null
  if (typeof ts === 'number' && Number.isFinite(ts)) {
    const ms = ts < 1e12 ? ts * 1000 : ts
    const d = new Date(ms)
    return Number.isNaN(d.getTime()) ? null : d
  }
  const raw = String(ts).trim()
  if (!raw) return null
  if (/^\d+(\.\d+)?$/.test(raw)) {
    const n = Number(raw)
    const ms = n < 1e12 ? n * 1000 : n
    const d = new Date(ms)
    return Number.isNaN(d.getTime()) ? null : d
  }
  const d = new Date(raw)
  return Number.isNaN(d.getTime()) ? null : d
}

export function formatLogClock(ts: string | number | null | undefined): string {
  const d = parseLogDate(ts)
  if (!d) return ts == null || ts === '' ? '—' : String(ts)
  const pad = (n: number, w = 2) => String(n).padStart(w, '0')
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`
}

export function formatShortDate(ts: string | number | null | undefined): string {
  const d = parseLogDate(ts)
  if (!d) return '—'
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' })
}
