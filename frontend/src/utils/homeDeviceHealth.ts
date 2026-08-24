/** Home dashboard health display (PAS-52). */

import { DEVICE_LABEL } from './terminology'

/** CPU/memory from the health snapshot. Never GPU occupancy (gpu-devices). */
export function deviceResourcesLine(device: {
  reachability?: string
  resources?: {
    cpuLoadPercent?: number | null
    memoryUsedMB?: number | null
    memoryTotalMB?: number | null
  } | null
}): string | null {
  if (device.reachability !== 'ok' || !device.resources) return null
  const parts: string[] = []
  if (device.resources.cpuLoadPercent != null) {
    parts.push(`CPU ${Math.round(device.resources.cpuLoadPercent)}%`)
  }
  if (device.resources.memoryUsedMB != null && device.resources.memoryTotalMB != null) {
    parts.push(
      `${(device.resources.memoryUsedMB / 1024).toFixed(1)} / ${(device.resources.memoryTotalMB / 1024).toFixed(0)} GB`,
    )
  }
  return parts.length ? parts.join(' · ') : null
}

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

export function isReachabilityOk(code: string | undefined): boolean {
  return code === 'ok'
}

/** Pill on Device cards and Device detail. `memberHTTP` is not Unreachable. */
export function reachabilityLabel(code: string | undefined): string {
  switch (code) {
    case 'ok':
      return 'Reachable'
    case 'connectTimeout':
      return 'Timed out'
    case 'cancelled':
      return 'Cancelled'
    case 'tlsFailure':
      return 'TLS failed'
    case 'memberHTTP':
      return 'HTTP error'
    default:
      return 'Unreachable'
  }
}

export function reachabilityPillClass(code: string | undefined): string {
  if (code === 'ok') return 'running'
  if (code === 'memberHTTP') return 'degraded'
  return 'failed'
}

export function reachabilityCardClass(code: string | undefined): string {
  if (code === 'ok' || !code) return ''
  if (code === 'memberHTTP') return 'http-error'
  return 'unreachable'
}

export function reachabilityHint(
  device: { reachability?: string; reachabilityError?: string | null },
): string | null {
  const code = device.reachability
  if (!code || code === 'ok') return null
  if (code === 'unreachable') {
    return `This ${DEVICE_LABEL.toLowerCase()} is still running locally. The member did not answer.`
  }
  const error = device.reachabilityError?.trim()
  return error || reachabilityLabel(code)
}
