import { describe, expect, test } from 'vitest'
import {
  buildAddressApplyEntries,
  buildHostBridgeApplyBody,
  isValidCIDR,
  validateAddressList,
} from './hostInterfaceAddresses'

describe('hostInterfaceAddresses', () => {
  test('validates CIDR format and duplicates', () => {
    expect(isValidCIDR('192.168.1.10/24')).toBe(true)
    expect(isValidCIDR('bad')).toBe(false)
    const invalid = validateAddressList([
      { id: '1', kind: 'static', cidr: 'not-a-cidr' },
    ])
    expect(invalid.ok).toBe(false)
    expect(invalid.errors[0]).toContain('Invalid CIDR')

    const dup = validateAddressList([
      { id: '1', kind: 'static', cidr: '10.0.0.2/24' },
      { id: '2', kind: 'alias', cidr: '10.0.0.2/24' },
    ])
    expect(dup.ok).toBe(false)
    expect(dup.errors[0]).toContain('Duplicate')
  })

  test('requires dhcp or static source', () => {
    const empty = validateAddressList([])
    expect(empty.ok).toBe(false)
    const dhcpOnly = validateAddressList([{ id: 'd', kind: 'dhcp', cidr: '' }])
    expect(dhcpOnly.ok).toBe(true)
  })

  test('buildAddressApplyEntries maps dhcp and static rows', () => {
    expect(buildAddressApplyEntries([
      { id: 'd', kind: 'dhcp', cidr: '' },
      { id: 'a', kind: 'alias', cidr: '10.0.0.2/24' },
    ])).toEqual([
      { kind: 'dhcp' },
      { kind: 'alias', cidr: '10.0.0.2/24' },
    ])
  })

  test('buildHostBridgeApplyBody sends addresses array for multi-ip', () => {
    const body = buildHostBridgeApplyBody({
      nic: 'eth0',
      confirm: true,
      rows: [
        { id: 'd', kind: 'dhcp', cidr: '' },
        { id: 'a', kind: 'alias', cidr: '10.0.0.2/24' },
      ],
      gateway: '192.168.1.1',
      dns: '1.1.1.1',
    })
    expect(body.interface).toBe('eth0')
    expect(body.addresses).toEqual([
      { kind: 'dhcp' },
      { kind: 'alias', cidr: '10.0.0.2/24' },
    ])
    expect(body.gateway).toBe('192.168.1.1')
    expect(body.dns).toEqual(['1.1.1.1'])
  })

  test('buildHostBridgeApplyBody sends bridge with nic', () => {
    const body = buildHostBridgeApplyBody({
      nic: 'eth1',
      bridge: 'br1',
      confirm: true,
      rows: [{ id: 'd', kind: 'dhcp', cidr: '' }],
    })
    expect(body.interface).toBe('eth1')
    expect(body.bridge).toBe('br1')
    expect(body.action).toBe('apply')
  })

  test('check action body includes addresses', () => {
    const body = buildHostBridgeApplyBody({
      nic: 'eth0',
      action: 'check',
      rows: [{ id: 'd', kind: 'dhcp', cidr: '' }],
    })
    expect(body.action).toBe('check')
    expect(body.addresses).toEqual([{ kind: 'dhcp' }])
  })
})
