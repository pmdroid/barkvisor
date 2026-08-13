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
