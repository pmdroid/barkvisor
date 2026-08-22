import { describe, expect, test } from 'bun:test'
import { hasReachabilityAddresses } from './deviceAddresses'

describe('device reachability addresses (PAS-63)', () => {
  test('false when missing or both lists empty', () => {
    expect(hasReachabilityAddresses(undefined)).toBe(false)
    expect(hasReachabilityAddresses(null)).toBe(false)
    expect(hasReachabilityAddresses({ lan: [], tailnet: [] })).toBe(false)
  })

  test('true when LAN or tailnet has an address', () => {
    expect(hasReachabilityAddresses({ lan: ['192.168.0.8'], tailnet: [] })).toBe(true)
    expect(hasReachabilityAddresses({ lan: [], tailnet: ['100.64.1.2'] })).toBe(true)
  })
})
