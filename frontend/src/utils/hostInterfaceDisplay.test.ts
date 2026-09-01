import { describe, expect, test } from 'vitest'
import type { HostInterface } from '../api/types'
import {
  bridgeSetupInterfaceKey,
  formatInterfaceAddressSummary,
  hostBridgeActionPath,
  inferInterfaceRole,
  interfaceShowsDelete,
  interfaceBridgeColumn,
  interfaceBridgeRoleDetail,
  interfaceOwnsBridgeApply,
  interfaceRouteColumn,
  interfaceRoleLabel,
  pendingCommitMatchesInterface,
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

  test('bridge role detail describes uplink, bridge master, and external', () => {
    const ready = {
      defaultRouteInterface: 'eth0',
      bridges: [{ name: 'br0', enslaved: ['eth0'] }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: true,
    }
    expect(interfaceBridgeRoleDetail('uplink', iface({ name: 'eth0' }), ready, 'linux-guide'))
      .toBe('Uplink · enslaved to br0')
    expect(interfaceBridgeRoleDetail('uplink', iface({ name: 'eth0' }), { ...ready, bridges: [] }, 'linux-guide'))
      .toBe('Uplink · use as bridge uplink')
    expect(interfaceBridgeRoleDetail('bridge', iface({ name: 'br0' }), ready, 'linux-guide'))
      .toBe('Bridge · master (eth0)')
    expect(interfaceBridgeRoleDetail('external', iface({ name: 'docker0' }), ready, 'linux-guide'))
      .toBe('External · read-only')
    expect(interfaceBridgeRoleDetail('uplink', iface({ name: 'en0' }), ready, 'macos-guide'))
      .toBe('Uplink · socket_vmnet')
  })

  test('interfaceOwnsBridgeApply gates Apply to uplink/br0 only', () => {
    const pending = {
      defaultRouteInterface: 'eth0',
      bridges: [],
      onlyUplink: false,
      ready: false,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: null,
    }
    const ready = {
      ...pending,
      bridges: [{ name: 'br0', enslaved: ['eth0'] }],
      ready: true,
      aclAllowsSuggested: true,
    }
    expect(interfaceOwnsBridgeApply('uplink', iface({ name: 'eth0' }), pending, 'linux-guide')).toBe(true)
    expect(interfaceOwnsBridgeApply('uplink', iface({ name: 'eth0' }), ready, 'linux-guide')).toBe(false)
    expect(interfaceOwnsBridgeApply('bridge', iface({ name: 'br0' }), ready, 'linux-guide')).toBe(true)
    expect(interfaceOwnsBridgeApply('external', iface({ name: 'docker0' }), ready, 'linux-guide')).toBe(false)
    expect(interfaceOwnsBridgeApply('uplink', iface({ name: 'en0' }), ready, 'macos-guide')).toBe(true)
    expect(interfaceOwnsBridgeApply('bridge', iface({ name: 'br0' }), ready, 'macos-guide')).toBe(false)
  })

  test('bridgeSetupInterfaceKey prefers br0 on Linux and uplink on Mac', () => {
    const ready = {
      defaultRouteInterface: 'eth0',
      bridges: [{ name: 'br0', enslaved: [] }],
      onlyUplink: false,
      ready: false,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: null,
    }
    expect(bridgeSetupInterfaceKey('host-1', ready, 'linux-guide')).toBe('host-1:br0')
    expect(bridgeSetupInterfaceKey('host-1', ready, 'macos-guide')).toBe('host-1:eth0')
    expect(bridgeSetupInterfaceKey('host-1', { ...ready, bridges: [] }, 'linux-guide')).toBe('host-1:eth0')
  })

  test('Keep match and DELETE path use pending.target not br0', () => {
    const pending = { target: 'br1', nic: 'eth1' }
    expect(pendingCommitMatchesInterface(pending, 'eth1', 'linux-guide')).toBe(true)
    expect(pendingCommitMatchesInterface(pending, 'br1', 'linux-guide')).toBe(true)
    expect(pendingCommitMatchesInterface(pending, 'eth0', 'linux-guide')).toBe(false)
    expect(pendingCommitMatchesInterface({ target: 'en0', nic: 'en0' }, 'en0', 'macos-guide')).toBe(true)
    expect(hostBridgeActionPath('/system/bridges', 'eth1', 'linux-guide', 'br1'))
      .toBe('/system/bridges/br1')
    expect(hostBridgeActionPath('/system/bridges', 'eth1', 'linux-guide', 'br0'))
      .not.toBe('/system/bridges/br1')
    expect(hostBridgeActionPath('/system/bridges', 'en0', 'macos-guide', 'br1'))
      .toBe('/system/bridges/en0')
  })

  test('Delete vs Revert follows createdBridge on the marker snapshot', () => {
    const owned = {
      defaultRouteInterface: 'eth0',
      bridges: [{ name: 'br1', enslaved: ['eth0'], createdBridge: true }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br1',
      aclAllowsSuggested: true,
    }
    const foreign = {
      ...owned,
      bridges: [{ name: 'br0', enslaved: ['eth0'], createdBridge: false }],
    }
    expect(interfaceShowsDelete(iface({ name: 'br1' }), owned)).toBe(true)
    expect(interfaceShowsDelete(iface({ name: 'eth0' }), owned)).toBe(true)
    expect(interfaceShowsDelete(iface({ name: 'br0' }), foreign)).toBe(false)
    expect(interfaceShowsDelete(iface({ name: 'eth0' }), foreign)).toBe(false)
  })
})
