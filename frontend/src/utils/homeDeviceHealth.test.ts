import { describe, expect, test } from 'bun:test'
import {
  deviceWorkloadLine,
  hasKnownHealthCounts,
  homeWorkloadsRunningLine,
  resolveHealthCounts,
} from './homeDeviceHealth'

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
