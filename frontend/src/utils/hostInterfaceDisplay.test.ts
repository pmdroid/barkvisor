import { describe, expect, test } from 'vitest'
import type { HostInterface } from '../api/types'
import {
  formatInterfaceAddressSummary,
  inferInterfaceRole,
  interfaceBridgeColumn,
  interfaceRouteColumn,
  interfaceRoleLabel,
} from './hostInterfaceDisplay'

function iface(over: Partial<HostInterface> = {}): HostInterface {
  return {
    name: 'eth0',
    displayName: 'eth0',
    ipAddress: '192.168.1.10',
    ...over,
  }
}

describe('hostInterfaceDisplay', () => {
  test('infers uplink from default route', () => {
    expect(inferInterfaceRole(
      iface({ name: 'en0' }),
      { defaultRouteInterface: 'en0', bridges: [], onlyUplink: false, ready: false, helperPath: null, helperSetuid: false, suggestedBridge: 'br0', aclAllowsSuggested: null },
    )).toBe('uplink')
  })

  test('infers bridge from readiness snapshot', () => {
    expect(inferInterfaceRole(
      iface({ name: 'br0' }),
      { defaultRouteInterface: 'eth0', bridges: [{ name: 'br0', enslaved: ['eth0'] }], onlyUplink: false, ready: true, helperPath: null, helperSetuid: false, suggestedBridge: 'br0', aclAllowsSuggested: true },
    )).toBe('bridge')
  })

  test('formats dhcp plus static alias summary', () => {
    expect(formatInterfaceAddressSummary(iface({
      dhcpEnabled: true,
      ipAddress: '192.168.30.50',
      addresses: [
        { cidr: '192.168.30.50/24', source: 'dhcp', primary: true },
        { cidr: '10.0.0.2/24', source: 'alias', primary: false },
      ],
    }))).toBe('DHCP 192.168.30.50 + 10.0.0.2/24')
  })

  test('bridge column shows macos socket_vmnet when active', () => {
    expect(interfaceBridgeColumn(
      iface({ name: 'en0' }),
      null,
      { interface: 'en0', socketPath: '/x', plistExists: true, daemonRunning: true, status: 'active', updatedAt: '' },
      'macos-guide',
    )).toBe('socket_vmnet')
  })

  test('route column marks default uplink', () => {
    expect(interfaceRouteColumn(
      iface({ name: 'en0' }),
      { defaultRouteInterface: 'en0', bridges: [], onlyUplink: false, ready: false, helperPath: null, helperSetuid: false, suggestedBridge: 'br0', aclAllowsSuggested: null },
    )).toBe('default')
    expect(interfaceRoleLabel('uplink')).toBe('Uplink')
  })
})
