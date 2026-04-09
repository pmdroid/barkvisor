export function formatBytes(b: number | null | undefined): string {
  if (!b) return '-'
  if (b >= 1e9) return (b / 1e9).toFixed(1) + ' GB'
  if (b >= 1e6) return (b / 1e6).toFixed(1) + ' MB'
  if (b >= 1e3) return (b / 1e3).toFixed(0) + ' KB'
  return b + ' B'
}

export function pct(used: number, total: number): number {
  if (!total) return 0
  return Math.round((used / total) * 100)
}
