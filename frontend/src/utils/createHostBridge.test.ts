import { describe, expect, test } from 'bun:test'
import type { HostBridgeReadiness, HostInterface } from '../api/types'
import {
  defaultUnusedPort,
  linuxRefusesWifiPort,
  nextFreeBridgeName,
  takenBridgeNames,
  unusedBridgePorts,
} from './createHostBridge'

function iface(over: Partial<HostInterface> & { name: string }): HostInterface {
  return {
    displayName: over.displayName ?? over.name,
    ipAddress: '',
    ...over,
  }
}

function ready(over: Partial<HostBridgeReadiness> = {}): HostBridgeReadiness {
  return {
    helperPath: null,
    helperSetuid: false,
    suggestedBridge: 'br0',
    aclAllowsSuggested: null,
    bridges: [],
    defaultRouteInterface: 'eth0',
    onlyUplink: false,
    ready: false,
    ...over,
  }
}

describe('createHostBridge', () => {
  test('next-free skips kernel and marked names', () => {
    expect(nextFreeBridgeName([])).toBe('br0')
    expect(nextFreeBridgeName(['br0', 'eth0'])).toBe('br1')
    expect(nextFreeBridgeName(['br0', 'br1'])).toBe('br2')
    expect(takenBridgeNames(
      [iface({ name: 'eth0' }), iface({ name: 'br0' })],
      ready({ bridges: [{ name: 'br1', enslaved: [] }] }),
    ).sort()).toEqual(['br0', 'br1'])
  })

  test('Linux refuses Wi-Fi as port; Mac en0 is allowed', () => {
    expect(linuxRefusesWifiPort(iface({ name: 'wlan0' }), 'linux')).toBe(true)
    expect(linuxRefusesWifiPort(iface({ name: 'wlp2s0' }), 'Linux')).toBe(true)
    expect(linuxRefusesWifiPort(iface({ name: 'en0', displayName: 'en0 (Wi-Fi)' }), 'linux')).toBe(true)
    expect(linuxRefusesWifiPort(iface({ name: 'eth0' }), 'linux')).toBe(false)
    expect(linuxRefusesWifiPort(iface({ name: 'en0', displayName: 'en0 (Wi-Fi)' }), 'macos')).toBe(false)
    expect(linuxRefusesWifiPort(iface({ name: 'en0', displayName: 'en0 (Wi-Fi)' }), 'darwin')).toBe(false)
  })

  test('unused ports skip enslaved, bridges, and Linux Wi-Fi', () => {
    const ifaces = [
      iface({ name: 'lo' }),
      iface({ name: 'eth0' }),
      iface({ name: 'eth1' }),
      iface({ name: 'wlan0' }),
      iface({ name: 'br0' }),
      iface({ name: 'docker0' }),
    ]
    const linux = unusedBridgePorts(
      ifaces,
      ready({
        bridges: [{ name: 'br0', enslaved: ['eth0'] }],
        defaultRouteInterface: 'eth0',
      }),
      'linux',
    )
    expect(linux.map((row) => row.name)).toEqual(['eth1'])

    const mac = unusedBridgePorts(
      [iface({ name: 'en0', displayName: 'en0 (Wi-Fi)' }), iface({ name: 'en1' })],
      ready({ defaultRouteInterface: 'en0', bridges: [] }),
      'macos',
    )
    expect(mac.map((row) => row.name)).toEqual(['en0', 'en1'])
    expect(defaultUnusedPort(mac, ready({ defaultRouteInterface: 'en0' }))).toBe('en0')
  })
})
