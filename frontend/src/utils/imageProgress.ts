/** Live download event fields used to render a percent bar. */
export type ImageProgressPercentInput = {
  percent?: number | null
}

/**
 * Display percent 0-100. Null means unknown total (indeterminate bar).
 * The server already sends 0-100; values in 0-1 are not treated as fractions.
 */
export function imageProgressPercent(
  event: ImageProgressPercentInput | null | undefined,
): number | null {
  const raw = event?.percent
  if (typeof raw !== 'number' || Number.isNaN(raw)) return null
  return Math.round(Math.min(100, Math.max(0, raw)))
}
