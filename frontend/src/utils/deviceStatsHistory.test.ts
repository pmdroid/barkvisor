import { describe, expect, test } from 'bun:test'
import type { SystemStatsSample } from '../api/types'
import {
  DEVICE_STATS_HISTORY_MAX,
  emptyDeviceStatsChartSeries,
  mapStatsHistorySamples,
  shouldFetchDeviceStatsHistory,
} from './deviceStatsHistory'

const self = { hostId: 'desk-1', role: 'self', reachability: 'ok' }
const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }
const down = { hostId: 'peer-2', role: 'member', reachability: 'unreachable' }

function sample(
  timestamp: string,
  cpu: number,
  usedMB: number,
  totalMB = 32_768,
): SystemStatsSample {
  return {
    timestamp,
    hostCpuPercent: cpu,
    hostMemoryUsedMB: usedMB,
    hostMemoryTotalMB: totalMB,
  }
}

describe('device stats history mapping', () => {
  test('reachable self and members fetch; unreachable members skip', () => {
    expect(shouldFetchDeviceStatsHistory(self)).toBe(true)
    expect(shouldFetchDeviceStatsHistory({ ...self, reachability: 'unreachable' })).toBe(true)
    expect(shouldFetchDeviceStatsHistory(member)).toBe(true)
    expect(shouldFetchDeviceStatsHistory(down)).toBe(false)
  })

  test('maps CPU percent and memory GiB without fabricating points', () => {
    const series = mapStatsHistorySamples(
      [
        sample('2026-08-23T12:00:00Z', 12.4, 8_192),
        sample('2026-08-23T12:00:05Z', 40, 16_384),
      ],
      { formatTime: (ts) => ts },
    )
    expect(series.labels).toEqual(['2026-08-23T12:00:00Z', '2026-08-23T12:00:05Z'])
    expect(series.cpu).toEqual([12.4, 40])
    expect(series.memoryGB).toEqual([8, 16])
    expect(series.memoryTotalGB).toBe(32)
  })

  test('empty or missing payload is no series', () => {
    expect(mapStatsHistorySamples([])).toEqual(emptyDeviceStatsChartSeries())
    expect(mapStatsHistorySamples([] as SystemStatsSample[])).toEqual({
      labels: [],
      cpu: [],
      memoryGB: [],
      memoryTotalGB: undefined,
    })
  })

  test(`keeps the last ${DEVICE_STATS_HISTORY_MAX} samples`, () => {
    const samples = Array.from({ length: DEVICE_STATS_HISTORY_MAX + 5 }, (_, i) =>
      sample(`t-${i}`, i, 1_024),
    )
    const series = mapStatsHistorySamples(samples, { formatTime: (ts) => ts })
    expect(series.labels).toHaveLength(DEVICE_STATS_HISTORY_MAX)
    expect(series.labels[0]).toBe('t-5')
    expect(series.cpu.at(-1)).toBe(DEVICE_STATS_HISTORY_MAX + 4)
  })
})
