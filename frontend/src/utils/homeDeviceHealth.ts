/** Home dashboard health display (PAS-52). */

export function deviceWorkloadLine(device: {
  reachability?: string
  workloadCount?: number | null
  healthCounts?: Record<string, number> | null
}): string {
  if (device.reachability !== 'ok') return 'Health unavailable'
  if (device.workloadCount == null) return 'Workloads unknown'
  const count = device.workloadCount
  const failed = device.healthCounts?.failed ?? 0
  if (failed > 0) return `${count} workloads · ${failed} failed`
  return `${count} workload${count === 1 ? '' : 's'}`
}

/** A successful summarize() always includes health keys (even all zeros).
 *  Empty `{}` means no device returned a health summary. */
export function hasKnownHealthCounts(
  counts?: Record<string, number> | null,
): counts is Record<string, number> {
  return counts != null && Object.keys(counts).length > 0
}

export function resolveHealthCounts(
  preferred?: Record<string, number> | null,
  fallback?: Record<string, number> | null,
): Record<string, number> {
  if (hasKnownHealthCounts(preferred)) return preferred
  return fallback ?? {}
}

/** Home-wide "X of Y workloads running". Null when the API reports unknown. */
export function homeWorkloadsRunningLine(
  totals: { workloadCount?: number | null } | null | undefined,
  runningCount: number,
): string | null {
  if (totals?.workloadCount == null) return null
  return `${runningCount} of ${totals.workloadCount} workloads running`
}
