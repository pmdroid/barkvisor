import type { MetricSample, SystemStats, VM } from '../api/types'
import { formatMemoryMB } from './format'

export const APP_METRICS_INTERVAL_SECONDS = 5

export function isAppRunning(vm: Pick<VM, 'state'> | null | undefined): boolean {
  return vm?.state === 'running'
}

export function latestAppSample(
  samples: readonly MetricSample[] | null | undefined,
): MetricSample | null {
  if (!samples || samples.length === 0) return null
  return samples[samples.length - 1] ?? null
}

export function formatCpuPercent(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return '—'
  return `${value.toFixed(1)}%`
}

export function formatBytesPerSec(bytesPerSec: number | null | undefined): string {
  if (bytesPerSec == null || !Number.isFinite(bytesPerSec)) return '—'
  if (bytesPerSec >= 1_000_000_000) return `${(bytesPerSec / 1_000_000_000).toFixed(1)} GB/s`
  if (bytesPerSec >= 1_000_000) return `${(bytesPerSec / 1_000_000).toFixed(1)} MB/s`
  if (bytesPerSec >= 1_000) return `${(bytesPerSec / 1_000).toFixed(1)} KB/s`
  return `${Math.round(bytesPerSec)} B/s`
}

export function formatNetworkIOLabel(
  rxBytes: number | null | undefined,
  txBytes: number | null | undefined,
  intervalSeconds: number = APP_METRICS_INTERVAL_SECONDS,
): string {
  if (rxBytes == null || txBytes == null) return '—'
  if (!Number.isFinite(rxBytes) || !Number.isFinite(txBytes)) return '—'
  const divisor = intervalSeconds > 0 ? intervalSeconds : APP_METRICS_INTERVAL_SECONDS
  return `↓ ${formatBytesPerSec(rxBytes / divisor)} · ↑ ${formatBytesPerSec(txBytes / divisor)}`
}

export function clampFraction(value: number | null | undefined): number | null {
  if (value == null || !Number.isFinite(value)) return null
  return Math.min(Math.max(value, 0), 1)
}

export interface AppUsageSummary {
  cpuLabel: string
  cpuFraction: number | null
  memLabel: string
  memFraction: number | null
  netLabel: string
}

export function summarizeAppUsage(
  samples: readonly MetricSample[] | null | undefined,
): AppUsageSummary | null {
  const latest = latestAppSample(samples)
  if (!latest) return null
  const cpu = Number.isFinite(latest.cpuPercent) ? latest.cpuPercent : null
  const mem = Number.isFinite(latest.memoryUsedMB) ? latest.memoryUsedMB : null
  const limit = Number.isFinite(latest.memoryLimitMB ?? NaN) ? (latest.memoryLimitMB as number) : null
  const memLabel = mem == null
    ? '—'
    : limit != null && limit > 0
      ? `${formatMemoryMB(mem)} / ${formatMemoryMB(limit)}`
      : formatMemoryMB(mem)
  return {
    cpuLabel: formatCpuPercent(cpu),
    cpuFraction: cpu == null ? null : clampFraction(cpu / 100),
    memLabel,
    memFraction: mem != null && limit != null && limit > 0 ? clampFraction(mem / limit) : null,
    netLabel: formatNetworkIOLabel(latest.networkRxBytes, latest.networkTxBytes),
  }
}

export interface WorkloadUsageTotals {
  vmCpu: number
  vmMem: number
  appCpu: number
  appMem: number
  appRx: number
  appTx: number
  runningApps: number
  totalApps: number
}

export function workloadUsageTotals(stats: SystemStats | null | undefined): WorkloadUsageTotals {
  return {
    vmCpu: stats?.vmCpuPercent ?? 0,
    vmMem: stats?.vmMemoryMB ?? 0,
    appCpu: stats?.appCpuPercent ?? 0,
    appMem: stats?.appMemoryMB ?? 0,
    appRx: stats?.appNetworkRxBytes ?? 0,
    appTx: stats?.appNetworkTxBytes ?? 0,
    runningApps: stats?.runningApps ?? 0,
    totalApps: stats?.totalApps ?? 0,
  }
}

export function sumWorkloadUsage(
  list: readonly (SystemStats | null | undefined)[],
): WorkloadUsageTotals {
  const total: WorkloadUsageTotals = {
    vmCpu: 0,
    vmMem: 0,
    appCpu: 0,
    appMem: 0,
    appRx: 0,
    appTx: 0,
    runningApps: 0,
    totalApps: 0,
  }
  for (const stats of list) {
    const row = workloadUsageTotals(stats)
    total.vmCpu += row.vmCpu
    total.vmMem += row.vmMem
    total.appCpu += row.appCpu
    total.appMem += row.appMem
    total.appRx += row.appRx
    total.appTx += row.appTx
    total.runningApps += row.runningApps
    total.totalApps += row.totalApps
  }
  return total
}
