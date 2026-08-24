import { describe, expect, test } from 'bun:test'
import {
  deviceResourcesLine,
  deviceWorkloadLine,
  hasKnownHealthCounts,
  homeWorkloadsRunningLine,
  resolveHealthCounts,
} from './homeDeviceHealth'

describe('deviceResourcesLine', () => {
  test('reachable CPU and memory match the Device row, with no GPU copy', () => {
    const line = deviceResourcesLine({
      reachability: 'ok',
      resources: {
        cpuLoadPercent: 12.4,
        memoryUsedMB: 8192,
        memoryTotalMB: 32768,
      },
    })
    expect(line).toBe('CPU 12% · 8.0 / 32 GB')
    expect(line).not.toMatch(/gpu/i)
    expect(deviceResourcesLine({ reachability: 'unreachable', resources: { cpuLoadPercent: 90 } })).toBeNull()
    expect(deviceResourcesLine({ reachability: 'ok' })).toBeNull()
  })

  test('zero memory total is present, not treated as missing', () => {
    expect(
      deviceResourcesLine({
        reachability: 'ok',
        resources: {
          cpuLoadPercent: 0,
          memoryUsedMB: 0,
          memoryTotalMB: 0,
        },
      }),
    ).toBe('CPU 0% · 0.0 / 0 GB')
    expect(
      deviceResourcesLine({
        reachability: 'ok',
        resources: { memoryUsedMB: 512, memoryTotalMB: undefined },
      }),
    ).toBeNull()
  })
})

describe('deviceWorkloadLine', () => {
  test('reachable unknown count is not shown as zero workloads', () => {
    expect(deviceWorkloadLine({ reachability: 'ok', workloadCount: null })).toBe(
      'Workloads unknown',
    )
    expect(deviceWorkloadLine({ reachability: 'ok' })).toBe('Workloads unknown')
  })

  test('known zero stays zero and unreachable stays unavailable', () => {
    expect(deviceWorkloadLine({ reachability: 'ok', workloadCount: 0 })).toBe('0 workloads')
    expect(deviceWorkloadLine({ reachability: 'ok', workloadCount: 1 })).toBe('1 workload')
    expect(
      deviceWorkloadLine({
        reachability: 'ok',
        workloadCount: 3,
        healthCounts: { failed: 1 },
      }),
    ).toBe('3 workloads · 1 failed')
    expect(deviceWorkloadLine({ reachability: 'unreachable', workloadCount: null })).toBe(
      'Health unavailable',
    )
  })
})

describe('homeWorkloadsRunningLine', () => {
  test('unknown home-wide count is omitted instead of substituting a local total', () => {
    expect(homeWorkloadsRunningLine({ workloadCount: null }, 2)).toBeNull()
    expect(homeWorkloadsRunningLine({ workloadCount: undefined }, 2)).toBeNull()
    expect(homeWorkloadsRunningLine(null, 2)).toBeNull()
    expect(homeWorkloadsRunningLine(undefined, 2)).toBeNull()
  })

  test('known zero stays zero', () => {
    expect(homeWorkloadsRunningLine({ workloadCount: 0 }, 0)).toBe(
      '0 of 0 workloads running',
    )
    expect(homeWorkloadsRunningLine({ workloadCount: 5 }, 2)).toBe(
      '2 of 5 workloads running',
    )
  })
})

describe('resolveHealthCounts', () => {
  test('empty totals do not block fallback to the local health summary', () => {
    expect(hasKnownHealthCounts({})).toBe(false)
    expect(hasKnownHealthCounts(undefined)).toBe(false)
    expect(hasKnownHealthCounts({ running: 0, failed: 0 })).toBe(true)
    expect(resolveHealthCounts({}, { running: 2, failed: 1 })).toEqual({
      running: 2,
      failed: 1,
    })
    expect(resolveHealthCounts({ running: 0 }, { running: 4 })).toEqual({ running: 0 })
  })
})
