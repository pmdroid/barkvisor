import type { SystemStatsSample } from '../api/types'
import { canFetchDeviceWorkloads, type DeviceApiTarget } from './homeDeviceApi'

/** Dashboard sparkline cap — Device detail reuses the same window. */
export const DEVICE_STATS_HISTORY_MAX = 60
export const DEVICE_STATS_HISTORY_MINUTES = 30

export type DeviceStatsChartSeries = {
  labels: string[]
  cpu: number[]
  memoryGB: number[]
  memoryTotalGB: number | undefined
}

export function emptyDeviceStatsChartSeries(): DeviceStatsChartSeries {
  return { labels: [], cpu: [], memoryGB: [], memoryTotalGB: undefined }
}

/** Members must be reachable. Self uses local history. Never invent a series. */
export function shouldFetchDeviceStatsHistory(device: DeviceApiTarget): boolean {
  return canFetchDeviceWorkloads(device)
}

export function formatStatsHistoryTime(timestamp: string): string {
  const date = new Date(timestamp)
  if (Number.isNaN(date.getTime())) return timestamp
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

/** Map `GET /system/stats/history` samples to Chart.js series. CPU is percent; memory is GiB. */
export function mapStatsHistorySamples(
  samples: readonly SystemStatsSample[],
  options?: {
    max?: number
    formatTime?: (timestamp: string) => string
  },
): DeviceStatsChartSeries {
  if (!Array.isArray(samples) || samples.length === 0) return emptyDeviceStatsChartSeries()
  const max = options?.max ?? DEVICE_STATS_HISTORY_MAX
  const formatTime = options?.formatTime ?? formatStatsHistoryTime
  const sliced = samples.length > max ? samples.slice(samples.length - max) : samples
  const labels: string[] = []
  const cpu: number[] = []
  const memoryGB: number[] = []
  let memoryTotalGB: number | undefined
  for (const sample of sliced) {
    labels.push(formatTime(sample.timestamp))
    cpu.push(sample.hostCpuPercent)
    memoryGB.push(sample.hostMemoryUsedMB / 1024)
    memoryTotalGB = sample.hostMemoryTotalMB / 1024
  }
  return { labels, cpu, memoryGB, memoryTotalGB }
}
