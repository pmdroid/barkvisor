import { describe, expect, test } from 'bun:test'
import {
  deviceWorkloadLine,
  hasKnownHealthCounts,
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
