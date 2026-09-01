import { describe, expect, test } from 'vitest'
import type { HostInterface } from '../api/types'
import {
  addAdditionalAddress,
  addressesFromInterface,
  applyDhcpToggle,
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
      { id: '1', kind: 'primary', cidr: 'not-a-cidr' },
    ], { gateway: '192.168.1.1' })
    expect(invalid.ok).toBe(false)
    expect(invalid.errors[0]).toContain('Invalid CIDR')

    const dup = validateAddressList([
      { id: '1', kind: 'primary', cidr: '10.0.0.2/24' },
      { id: '2', kind: 'additional', cidr: '10.0.0.2/24' },
    ], { gateway: '10.0.0.1' })
    expect(dup.ok).toBe(false)
    expect(dup.errors[0]).toContain('Duplicate')
  })

  test('requires dhcp or primary with gateway for static mode', () => {
    const empty = validateAddressList([])
    expect(empty.ok).toBe(false)

    const dhcpOnly = validateAddressList([{ id: 'd', kind: 'dhcp', cidr: '' }])
    expect(dhcpOnly.ok).toBe(true)

    const staticNoGw = validateAddressList([
      { id: 'p', kind: 'primary', cidr: '192.168.1.10/24' },
    ])
    expect(staticNoGw.ok).toBe(false)
    expect(staticNoGw.errors.some((e) => e.includes('Gateway'))).toBe(true)

    const staticOk = validateAddressList([
      { id: 'p', kind: 'primary', cidr: '192.168.1.10/24' },
    ], { gateway: '192.168.1.1' })
    expect(staticOk.ok).toBe(true)
  })

  test('addressesFromInterface maps dhcp + extras and static primary', () => {
    const dhcpIface: HostInterface = {
      name: 'en0',
      dhcpEnabled: true,
      addresses: [
        { cidr: '192.168.8.224/16', source: 'dhcp', primary: true },
        { cidr: '192.168.10.10/16', source: 'alias', primary: false },
      ],
    }
    expect(addressesFromInterface(dhcpIface)).toEqual([
      { id: 'dhcp', kind: 'dhcp', cidr: '192.168.8.224/16' },
      { id: 'addr-192.168.10.10/16', kind: 'additional', cidr: '192.168.10.10/16' },
    ])

    const staticIface: HostInterface = {
      name: 'eth0',
      dhcpEnabled: false,
      gateway: '192.168.1.1',
      addresses: [
        { cidr: '192.168.1.10/24', source: 'static', primary: true },
        { cidr: '10.0.0.2/24', source: 'alias', primary: false },
      ],
    }
    expect(addressesFromInterface(staticIface)).toEqual([
      { id: 'primary', kind: 'primary', cidr: '192.168.1.10/24' },
      { id: 'addr-10.0.0.2/24', kind: 'additional', cidr: '10.0.0.2/24' },
    ])
  })

  test('applyDhcpToggle keeps primary cidr on dhcp row when enabling dhcp', () => {
    const staticRows = [
      { id: 'primary', kind: 'primary' as const, cidr: '192.168.1.10/24' },
      { id: 'a1', kind: 'additional' as const, cidr: '10.0.0.2/24' },
    ]
    expect(applyDhcpToggle(staticRows, true)).toEqual([
      { id: 'dhcp', kind: 'dhcp', cidr: '192.168.1.10/24' },
      { id: 'a1', kind: 'additional', cidr: '10.0.0.2/24' },
    ])
  })

  test('applyDhcpToggle adds primary row when disabling dhcp', () => {
    expect(applyDhcpToggle([{ id: 'dhcp', kind: 'dhcp', cidr: '' }], false)).toEqual([
      { id: 'primary', kind: 'primary', cidr: '' },
    ])
    expect(applyDhcpToggle([{ id: 'dhcp', kind: 'dhcp', cidr: '192.168.8.224/16' }], false)).toEqual([
      { id: 'primary', kind: 'primary', cidr: '192.168.8.224/16' },
    ])
  })

  test('buildAddressApplyEntries maps primary vs additional for backend', () => {
    expect(buildAddressApplyEntries([
      { id: 'd', kind: 'dhcp', cidr: '' },
      { id: 'a', kind: 'additional', cidr: '10.0.0.2/24' },
    ])).toEqual([
      { kind: 'dhcp' },
      { kind: 'alias', cidr: '10.0.0.2/24' },
    ])

    expect(buildAddressApplyEntries([
      { id: 'p', kind: 'primary', cidr: '192.168.1.10/24' },
      { id: 'a', kind: 'additional', cidr: '10.0.0.2/24' },
    ])).toEqual([
      { kind: 'static', cidr: '192.168.1.10/24' },
      { kind: 'alias', cidr: '10.0.0.2/24' },
    ])
  })

  test('buildHostBridgeApplyBody sends addresses array for multi-ip', () => {
    const body = buildHostBridgeApplyBody({
      nic: 'eth0',
      confirm: true,
      rows: [
        { id: 'd', kind: 'dhcp', cidr: '' },
        { id: 'a', kind: 'additional', cidr: '10.0.0.2/24' },
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

  test('addAdditionalAddress appends editable row', () => {
    const next = addAdditionalAddress([{ id: 'dhcp', kind: 'dhcp', cidr: '' }])
    expect(next).toHaveLength(2)
    expect(next[1]?.kind).toBe('additional')
    expect(next[1]?.cidr).toBe('')
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
