import { describe, expect, test } from 'vitest'
import type { HostInterface } from '../api/types'
import {
  addressApplyTargets,
  bridgedPickerInterfaces,
  bridgeSetupInterfaceKey,
  formatInterfaceAddressSummary,
  hostBridgeActionPath,
  hostInterfaceListed,
  inferInterfaceRole,
  interfaceAddressColumn,
  interfaceShowsDelete,
  interfaceBridgeColumn,
  interfaceBridgeRoleDetail,
  interfaceOwnsAddressApply,
  interfaceOwnsBridgeApply,
  interfaceRouteColumn,
  interfaceRoleLabel,
  overlayBridgeAddresses,
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

  test('does not treat Apple vmnet bridgeNNN or socket en0 as a BarkVisor bridge', () => {
    const ready = {
      defaultRouteInterface: 'en0',
      bridges: [{ name: 'en0', enslaved: [] }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: null,
    }
    expect(inferInterfaceRole(iface({ name: 'en0' }), ready)).toBe('uplink')
    expect(inferInterfaceRole(iface({ name: 'bridge100' }), ready)).toBe('external')
    expect(hostInterfaceListed(iface({ name: 'bridge100' }))).toBe(false)
    expect(hostInterfaceListed(iface({ name: 'en0' }))).toBe(true)
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

  test('interfaceOwnsAddressApply is the Bridge row on Linux and Mac', () => {
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
    expect(interfaceOwnsAddressApply('bridge', iface({ name: 'br0' }), ready, 'linux-guide')).toBe(true)
    expect(interfaceOwnsAddressApply('uplink', iface({ name: 'eth0' }), ready, 'linux-guide')).toBe(false)
    expect(interfaceOwnsAddressApply('bridge', iface({ name: 'br0' }), ready, 'macos-guide')).toBe(true)
    expect(interfaceOwnsAddressApply('uplink', iface({ name: 'en0' }), ready, 'macos-guide')).toBe(true)
    expect(interfaceOwnsAddressApply('external', iface({ name: 'docker0' }), ready, 'linux-guide')).toBe(false)
  })

  test('addressApplyTargets uses enslaved member and Mac uplink map', () => {
    const linux = {
      defaultRouteInterface: 'eth0',
      bridges: [{ name: 'br0', enslaved: ['eth0'] }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: true,
    }
    expect(addressApplyTargets(iface({ name: 'br0' }), linux, 'linux-guide'))
      .toEqual({ nic: 'eth0', bridge: 'br0' })
    const macMapped = {
      ...linux,
      defaultRouteInterface: 'en0',
      bridges: [{ name: 'br0', enslaved: ['en0'] }],
    }
    expect(addressApplyTargets(iface({ name: 'br0' }), macMapped, 'macos-guide'))
      .toEqual({ nic: 'en0', bridge: 'br0' })
    expect(addressApplyTargets(iface({ name: 'br0' }), { ...linux, bridges: [{ name: 'br0', enslaved: [] }] }, 'linux-guide'))
      .toEqual({ nic: 'br0', bridge: 'br0' })
  })

  test('address column shows IPs on brN and hides them on the enslaved NIC', () => {
    const ready = {
      defaultRouteInterface: 'en0',
      bridges: [{ name: 'br0', enslaved: ['en0'] }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: true,
    }
    const en0 = iface({
      name: 'en0',
      ipAddress: '192.168.1.10',
      dhcpEnabled: true,
      addresses: [{ cidr: '192.168.1.10/24', source: 'dhcp', primary: true }],
    })
    const br0 = iface({ name: 'br0', ipAddress: '', displayName: 'br0' })
    expect(interfaceAddressColumn(en0, [en0, br0], ready)).toBe('—')
    expect(interfaceAddressColumn(br0, [en0, br0], ready)).toBe('DHCP 192.168.1.10')
    expect(overlayBridgeAddresses(br0, [en0, br0], ready).ipAddress).toBe('192.168.1.10')
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

  test('VM picker lists brN not raw uplink when synthetic bridge exists', () => {
    const ready = {
      defaultRouteInterface: 'en0',
      bridges: [{ name: 'br0', enslaved: ['en0'] }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: null,
    }
    const ifaces = [
      iface({ name: 'en0', ipAddress: '192.168.1.10' }),
      iface({ name: 'br0', ipAddress: '192.168.1.10' }),
      iface({ name: 'lo0' }),
    ]
    expect(bridgedPickerInterfaces(ifaces, ready).map((row) => row.name)).toEqual(['br0'])
    expect(bridgedPickerInterfaces(ifaces, ready, 'en0').map((row) => row.name)).toEqual(['en0', 'br0'])
    expect(bridgedPickerInterfaces(
      [iface({ name: 'en0' }), iface({ name: 'lo0' })],
      { ...ready, bridges: [] },
    ).map((row) => row.name)).toEqual(['en0', 'lo0'])
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
