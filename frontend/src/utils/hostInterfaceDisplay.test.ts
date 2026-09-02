import { describe, expect, test } from 'vitest'
import type { HostInterface } from '../api/types'
import {
  addressApplyTargets,
  bridgedPickerInterfaces,
  bridgeSetupInterfaceKey,
  formatInterfaceAddressSummary,
  formatInterfaceLinkSummary,
  hostBridgeActionPath,
  inferInterfaceRole,
  interfaceAddressColumn,
  interfaceAddressFieldsReadOnly,
  interfaceShowsDelete,
  syntheticMacBridgeIfaces,
  interfaceBridgeColumn,
  interfaceBridgeRoleDetail,
  interfaceOwnsAddressApply,
  interfaceOwnsBridgeApply,
  interfaceOwnsBridgeSetupApply,
  interfaceRouteColumn,
  interfaceRoleLabel,
  existingBridgeForInterfaceApply,
  overlayBridgeAddresses,
  pendingCommitBridgeName,
  pendingCommitMatchesInterface,
  resolveBridgeApplyNic,
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
      'linux-guide',
    )).toBe('bridge')
  })

  test('mac socket_vmnet uplink stays uplink not bridge', () => {
    const ready = {
      defaultRouteInterface: 'en0',
      bridges: [{ name: 'en0', enslaved: [] as string[] }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: null,
    }
    expect(inferInterfaceRole(iface({ name: 'en0' }), ready, 'macos-guide')).toBe('uplink')
    expect(inferInterfaceRole(iface({ name: 'en0' }), ready, 'linux-guide')).toBe('bridge')
    expect(interfaceOwnsAddressApply('uplink', iface({ name: 'en0' }), ready, 'macos-guide')).toBe(true)
  })

  test('infers enslaved NIC without IPv4 as uplink', () => {
    expect(inferInterfaceRole(
      iface({ name: 'enp2s0', ipAddress: '' }),
      {
        defaultRouteInterface: 'br0',
        bridges: [{ name: 'br0', enslaved: ['enp2s0'] }],
        onlyUplink: false,
        ready: true,
        helperPath: null,
        helperSetuid: false,
        suggestedBridge: 'br0',
        aclAllowsSuggested: true,
      },
    )).toBe('uplink')
  })

  test('physical ethernet without address is uplink not external', () => {
    expect(inferInterfaceRole(
      iface({ name: 'enp1s0', ipAddress: '' }),
      {
        defaultRouteInterface: 'br0',
        bridges: [{ name: 'br0', enslaved: ['enp2s0'] }],
        onlyUplink: false,
        ready: true,
        helperPath: null,
        helperSetuid: false,
        suggestedBridge: 'br0',
        aclAllowsSuggested: true,
      },
    )).toBe('uplink')
  })

  test('link summary reflects operstate and carrier', () => {
    expect(formatInterfaceLinkSummary(iface({ operState: 'up', carrier: true }))).toBe('Up · plugged')
    expect(formatInterfaceLinkSummary(iface({ operState: 'down', carrier: false }))).toBe('Down · unplugged')
    expect(formatInterfaceLinkSummary(iface({ operState: 'up' }))).toBe('Up')
  })

  test('infers enslaved NIC from bridgeMaster when readiness missing', () => {
    expect(inferInterfaceRole(
      iface({ name: 'enp2s0', ipAddress: '', bridgeMaster: 'br0' }),
      null,
    )).toBe('uplink')
  })

  test('formats dhcp plus static alias summary', () => {
    expect(formatInterfaceAddressSummary(iface({
      dhcpEnabled: true,
      ipAddress: '192.168.30.50',
      addresses: [
        { cidr: '192.168.30.50/24', source: 'dhcp', primary: true },
        { cidr: '10.0.0.2/24', source: 'alias', primary: false },
      ],
    }))).toBe('DHCP 192.168.30.50 + 10.0.0.2/24 (extra)')
  })

  test('enslaved port without overlay IPs is blank', () => {
    const ready = {
      defaultRouteInterface: 'br0',
      bridges: [{ name: 'br0', enslaved: ['enp2s0'] }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: true,
    }
    expect(formatInterfaceAddressSummary(
      iface({ name: 'enp2s0', ipAddress: '', addresses: [], bridgeMaster: 'br0' }),
      ready,
      { mode: 'linux-guide', allIfaces: [] },
    )).toBe('—')
  })

  test('linux bridge L3 shown on enslaved port not br0 row', () => {
    const ready = {
      defaultRouteInterface: 'br0',
      bridges: [{ name: 'br0', enslaved: ['enp2s0'] }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: true,
    }
    const br0 = iface({
      name: 'br0',
      addresses: [
        { cidr: '192.168.30.1/16', source: 'static', primary: true },
        { cidr: '192.168.8.199/16', source: 'alias', primary: false },
      ],
    })
    const enp2 = iface({ name: 'enp2s0', ipAddress: '', addresses: [], bridgeMaster: 'br0' })
    const allIfaces = [br0, enp2]
    expect(formatInterfaceAddressSummary(br0, ready, { mode: 'linux-guide', allIfaces }))
      .toBe('—')
    expect(formatInterfaceAddressSummary(enp2, ready, { mode: 'linux-guide', allIfaces }))
      .toBe('192.168.30.1/16 + 192.168.8.199/16 (extra)')
  })

  test('bridge master address summary is blank', () => {
    expect(formatInterfaceAddressSummary(
      iface({
        name: 'br0',
        addresses: [
          { cidr: '192.168.30.1/16', source: 'static', primary: true },
          { cidr: '192.168.8.199/16', source: 'alias', primary: false },
        ],
      }),
      { defaultRouteInterface: 'br0', bridges: [{ name: 'br0', enslaved: ['enp2s0'] }], onlyUplink: false, ready: true, helperPath: null, helperSetuid: false, suggestedBridge: 'br0', aclAllowsSuggested: true },
      { mode: 'macos-guide' },
    )).toBe('—')
  })

  test('bridge column shows attached port on the Bridge row', () => {
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
    expect(interfaceBridgeColumn(iface({ name: 'br0' }), ready, undefined, 'macos-guide')).toBe('en0')
    expect(interfaceBridgeColumn(iface({ name: 'en0' }), ready, undefined, 'macos-guide')).toBe('→ br0')
    expect(interfaceBridgeColumn(
      iface({ name: 'en0' }),
      null,
      { interface: 'en0', socketPath: '/x', plistExists: true, daemonRunning: true, status: 'active', updatedAt: '' },
      'macos-guide',
    )).toBe('—')
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

  test('linux split apply: bridge setup vs port addresses', () => {
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
      bridges: [{ name: 'br0', enslaved: ['enp2s0'] }],
      ready: true,
      aclAllowsSuggested: true,
    }
    expect(interfaceOwnsBridgeSetupApply('uplink', iface({ name: 'eth0' }), pending, 'linux-guide')).toBe(true)
    expect(interfaceOwnsAddressApply('uplink', iface({ name: 'eth0' }), pending, 'linux-guide')).toBe(true)
    expect(interfaceOwnsBridgeSetupApply('uplink', iface({ name: 'enp2s0', bridgeMaster: 'br0' }), ready, 'linux-guide')).toBe(false)
    expect(interfaceOwnsAddressApply('uplink', iface({ name: 'enp2s0', bridgeMaster: 'br0' }), ready, 'linux-guide')).toBe(true)
    expect(interfaceOwnsBridgeSetupApply('bridge', iface({ name: 'br0' }), ready, 'linux-guide')).toBe(true)
    expect(interfaceOwnsBridgeSetupApply('bridge', iface({ name: 'br0' }), ready, 'macos-guide')).toBe(true)
    expect(interfaceOwnsAddressApply('bridge', iface({ name: 'br0' }), ready, 'linux-guide')).toBe(false)
    expect(interfaceOwnsBridgeApply('uplink', iface({ name: 'enp2s0', bridgeMaster: 'br0' }), ready, 'linux-guide')).toBe(true)
    expect(interfaceOwnsBridgeApply('bridge', iface({ name: 'br0' }), ready, 'linux-guide')).toBe(true)
    expect(interfaceOwnsBridgeApply('uplink', iface({ name: 'en0' }), ready, 'macos-guide')).toBe(true)
    expect(interfaceOwnsBridgeApply('bridge', iface({ name: 'br0' }), ready, 'macos-guide')).toBe(true)
  })

  test('interfaceOwnsAddressApply is the NIC row on Linux and Mac', () => {
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
    expect(interfaceOwnsAddressApply('bridge', iface({ name: 'br0' }), ready, 'linux-guide')).toBe(false)
    expect(interfaceOwnsAddressApply('uplink', iface({ name: 'eth0' }), ready, 'linux-guide')).toBe(true)
    expect(interfaceOwnsAddressApply('bridge', iface({ name: 'br0' }), ready, 'macos-guide')).toBe(false)
    expect(interfaceOwnsAddressApply('uplink', iface({ name: 'en0' }), ready, 'macos-guide')).toBe(true)
    expect(interfaceOwnsAddressApply('external', iface({ name: 'docker0' }), ready, 'linux-guide')).toBe(false)
  })

  test('existingBridgeForInterfaceApply is parent or self, never implied br0', () => {
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
      bridges: [{ name: 'br1', enslaved: ['eth1'] }],
      ready: true,
      aclAllowsSuggested: true,
    }
    expect(existingBridgeForInterfaceApply('uplink', iface({ name: 'eth0' }), pending)).toBe(null)
    expect(existingBridgeForInterfaceApply(
      'uplink',
      iface({ name: 'eth1', bridgeMaster: 'br1' }),
      ready,
    )).toBe('br1')
    expect(existingBridgeForInterfaceApply('bridge', iface({ name: 'br1' }), ready)).toBe('br1')
  })

  test('resolveBridgeApplyNic uses enslaved port when drawer targets br0', () => {
    const ready = {
      defaultRouteInterface: 'br0',
      bridges: [{ name: 'br0', enslaved: ['enp2s0', 'enp1s0'] }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: true,
    }
    expect(resolveBridgeApplyNic(iface({ name: 'br0' }), ready)).toBe('enp2s0')
    expect(resolveBridgeApplyNic(iface({ name: 'enp2s0' }), ready)).toBe('enp2s0')
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
    expect(addressApplyTargets(iface({ name: 'eth0' }), linux, 'linux-guide'))
      .toEqual({ nic: 'eth0', bridge: 'br0' })
    const macMapped = {
      ...linux,
      defaultRouteInterface: 'en0',
      bridges: [{ name: 'br0', enslaved: ['en0'] }],
    }
    expect(addressApplyTargets(iface({ name: 'en0' }), macMapped, 'macos-guide'))
      .toEqual({ nic: 'en0', bridge: 'br0' })
    expect(addressApplyTargets(iface({ name: 'en0' }), { ...linux, bridges: [] }, 'linux-guide'))
      .toEqual({ nic: 'en0', bridge: '' })
  })

  test('address column shows IPs on the NIC and hides them on the Bridge row', () => {
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
    expect(interfaceAddressColumn(en0, [en0, br0], ready)).toBe('DHCP 192.168.1.10')
    expect(interfaceAddressColumn(br0, [en0, br0], ready)).toBe('—')
    expect(overlayBridgeAddresses(en0, [en0, br0], ready).ipAddress).toBe('192.168.1.10')
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

  test('Mac Keep follows the NIC row when Apply sent nic en0', () => {
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
    const pending = { target: 'en0', nic: 'en0' }
    expect(pendingCommitBridgeName(pending, ready)).toBe('br0')
    expect(pendingCommitMatchesInterface(pending, 'br0', 'macos-guide', ready)).toBe(false)
    expect(pendingCommitMatchesInterface(pending, 'en0', 'macos-guide', ready)).toBe(true)
    expect(pendingCommitMatchesInterface({ target: 'br0', nic: 'en0' }, 'br0', 'macos-guide', ready)).toBe(false)
    expect(pendingCommitMatchesInterface({ target: 'br0', nic: 'en0' }, 'en0', 'macos-guide', ready)).toBe(true)
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

  test('syntheticMacBridgeIfaces adds brN rows that are not OS NICs', () => {
    const ready = {
      defaultRouteInterface: 'en0',
      bridges: [{ name: 'br0', enslaved: ['en0'], createdBridge: true }],
      onlyUplink: false,
      ready: true,
      helperPath: null,
      helperSetuid: false,
      suggestedBridge: 'br0',
      aclAllowsSuggested: null,
    }
    expect(syntheticMacBridgeIfaces([iface({ name: 'en0' })], ready, 'macos-guide').map((row) => row.name))
      .toEqual(['br0'])
    expect(syntheticMacBridgeIfaces([iface({ name: 'en0' })], ready, 'linux-guide')).toEqual([])
    expect(syntheticMacBridgeIfaces(
      [iface({ name: 'en0' })],
      { ...ready, bridges: [{ name: '', enslaved: ['en0'], createdBridge: true }] },
      'macos-guide',
    )).toEqual([])
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
})
