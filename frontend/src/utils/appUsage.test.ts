import { describe, expect, test } from 'bun:test'
import type { MetricSample } from '../api/types'
import {
  clampFraction,
  formatBytesPerSec,
  formatCpuPercent,
  formatNetworkIOLabel,
  isAppRunning,
  latestAppSample,
  summarizeAppUsage,
  sumWorkloadUsage,
  workloadUsageTotals,
} from './appUsage'

function sample(overrides: Partial<MetricSample> = {}): MetricSample {
  return {
    timestamp: '2026-09-10T00:00:00Z',
    cpuPercent: 2.5,
    memoryUsedMB: 128,
    diskReadBytes: 0,
    diskWriteBytes: 0,
    networkRxBytes: 10_000,
    networkTxBytes: 20_000,
    memoryLimitMB: 4096,
    ...overrides,
  }
}

describe('isAppRunning', () => {
  test('only the running state counts', () => {
    expect(isAppRunning({ state: 'running' })).toBe(true)
    expect(isAppRunning({ state: 'stopped' })).toBe(false)
    expect(isAppRunning({ state: 'error' })).toBe(false)
    expect(isAppRunning(null)).toBe(false)
    expect(isAppRunning(undefined)).toBe(false)
  })
})

describe('latestAppSample', () => {
  test('picks the newest sample', () => {
    const first = sample({ cpuPercent: 1 })
    const last = sample({ cpuPercent: 9 })
    expect(latestAppSample([first, last])).toBe(last)
  })

  test('empty input has no sample', () => {
    expect(latestAppSample([])).toBeNull()
    expect(latestAppSample(null)).toBeNull()
    expect(latestAppSample(undefined)).toBeNull()
  })
})

describe('formatting', () => {
  test('cpu percent keeps one decimal', () => {
    expect(formatCpuPercent(2.5)).toBe('2.5%')
    expect(formatCpuPercent(0)).toBe('0.0%')
    expect(formatCpuPercent(null)).toBe('—')
    expect(formatCpuPercent(NaN)).toBe('—')
  })

  test('throughput picks units', () => {
    expect(formatBytesPerSec(0)).toBe('0 B/s')
    expect(formatBytesPerSec(999)).toBe('999 B/s')
    expect(formatBytesPerSec(1500)).toBe('1.5 KB/s')
    expect(formatBytesPerSec(2_400_000)).toBe('2.4 MB/s')
    expect(formatBytesPerSec(null)).toBe('—')
  })

  test('network label rates the poll interval', () => {
    expect(formatNetworkIOLabel(10_000, 20_000, 5)).toBe('↓ 2.0 KB/s · ↑ 4.0 KB/s')
    expect(formatNetworkIOLabel(0, 0)).toBe('↓ 0 B/s · ↑ 0 B/s')
    expect(formatNetworkIOLabel(null, 20_000)).toBe('—')
    expect(formatNetworkIOLabel(undefined, undefined)).toBe('—')
  })

  test('fractions clamp to a bar', () => {
    expect(clampFraction(0.25)).toBe(0.25)
    expect(clampFraction(4)).toBe(1)
    expect(clampFraction(-1)).toBe(0)
    expect(clampFraction(null)).toBeNull()
  })
})

describe('summarizeAppUsage', () => {
  test('maps the newest sample to labels and bars', () => {
    const summary = summarizeAppUsage([sample({ cpuPercent: 1 }), sample()])
    expect(summary?.cpuLabel).toBe('2.5%')
    expect(summary?.cpuFraction).toBe(0.025)
    expect(summary?.memLabel).toBe('128 MB / 4 GB')
    expect(summary?.memFraction).toBeCloseTo(128 / 4096)
    expect(summary?.netLabel).toBe('↓ 2.0 KB/s · ↑ 4.0 KB/s')
  })

  test('memory without a limit hides the bar', () => {
    const summary = summarizeAppUsage([sample({ memoryLimitMB: 0 })])
    expect(summary?.memLabel).toBe('128 MB')
    expect(summary?.memFraction).toBeNull()
  })

  test('legacy samples without network fields still render', () => {
    const legacy = sample()
    delete legacy.networkRxBytes
    delete legacy.networkTxBytes
    delete legacy.memoryLimitMB
    const summary = summarizeAppUsage([legacy])
    expect(summary?.cpuLabel).toBe('2.5%')
    expect(summary?.netLabel).toBe('—')
    expect(summary?.memFraction).toBeNull()
  })

  test('no samples means no summary', () => {
    expect(summarizeAppUsage([])).toBeNull()
  })
})

describe('dashboard totals', () => {
  test('missing app fields default to zero', () => {
    expect(workloadUsageTotals(null)).toEqual({
      vmCpu: 0,
      vmMem: 0,
      appCpu: 0,
      appMem: 0,
      appRx: 0,
      appTx: 0,
      runningApps: 0,
      totalApps: 0,
    })
    expect(workloadUsageTotals({ vmCpuPercent: 3, vmMemoryMB: 100 } as never)).toEqual({
      vmCpu: 3,
      vmMem: 100,
      appCpu: 0,
      appMem: 0,
      appRx: 0,
      appTx: 0,
      runningApps: 0,
      totalApps: 0,
    })
  })

  test('device totals add up', () => {
    const total = sumWorkloadUsage([
      {
        hostCpuPercent: 1,
        hostMemoryTotalMB: 1,
        hostMemoryUsedMB: 1,
        runningVMs: 1,
        totalVMs: 1,
        vmCpuPercent: 3,
        vmMemoryMB: 100,
        appCpuPercent: 1,
        appMemoryMB: 50,
        appNetworkRxBytes: 10,
        appNetworkTxBytes: 20,
        runningApps: 1,
        totalApps: 2,
      },
      null,
      {
        hostCpuPercent: 1,
        hostMemoryTotalMB: 1,
        hostMemoryUsedMB: 1,
        runningVMs: 0,
        totalVMs: 0,
        vmCpuPercent: 2,
        vmMemoryMB: 10,
        appCpuPercent: 0.5,
        appMemoryMB: 5,
        appNetworkRxBytes: 1,
        appNetworkTxBytes: 2,
        runningApps: 0,
        totalApps: 1,
      },
    ])
    expect(total).toEqual({
      vmCpu: 5,
      vmMem: 110,
      appCpu: 1.5,
      appMem: 55,
      appRx: 11,
      appTx: 22,
      runningApps: 1,
      totalApps: 3,
    })
  })
})
