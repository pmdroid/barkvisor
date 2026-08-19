import { describe, expect, test } from 'bun:test'
import type { GuestInfo, GuestListeningPort } from '../api/types'
import {
  claimedNatTcpHostPorts,
  guestIpsReachableFromNetwork,
  guestListServiceChips,
  guestListeningPortAccessLabel,
  guestListeningPortHref,
  isLoopbackAddress,
  isPublishedGuestPort,
  isWildcardAddress,
  nextFreeHostPort,
  suggestPublishNatHostfwd,
} from './guestListeningPorts'

function port(partial: Partial<GuestListeningPort> & Pick<GuestListeningPort, 'port'>): GuestListeningPort {
  return {
    proto: 'tcp',
    address: '0.0.0.0',
    scope: 'network',
    label: null,
    ...partial,
  }
}

describe('guestListeningPorts (PAS-225)', () => {
  test('loopback is internal and never a URL', () => {
    expect(isLoopbackAddress('127.0.0.1')).toBe(true)
    expect(isLoopbackAddress('::1')).toBe(true)
    expect(isWildcardAddress('0.0.0.0')).toBe(true)
    expect(guestListeningPortHref(port({
      address: '127.0.0.1',
      port: 80,
      scope: 'internal',
      label: 'HTTP',
    }), ['10.0.0.5'])).toBeNull()
    expect(guestListeningPortAccessLabel(port({
      address: '127.0.0.1',
      port: 3000,
      scope: 'internal',
      label: 'Dev',
    }))).toBe('Internal')
  })

  test('HTTP on all interfaces uses the guest IP as a URL', () => {
    expect(guestListeningPortHref(port({
      address: '0.0.0.0',
      port: 80,
      label: 'HTTP',
    }), ['10.0.0.5'])).toBe('http://10.0.0.5')
    expect(guestListeningPortHref(port({
      address: '::',
      port: 443,
      label: 'HTTPS',
    }), ['2001:db8::1'])).toBe('https://[2001:db8::1]')
    expect(guestListeningPortHref(port({
      address: '10.0.0.5',
      port: 3000,
      label: 'Dev',
    }), ['10.0.0.5'])).toBe('http://10.0.0.5:3000')
  })

  test('HTTPS label uses https even when the port is not 443 or 9443', () => {
    expect(guestListeningPortHref(port({
      address: '10.0.0.5',
      port: 8443,
      label: 'HTTPS',
    }), ['10.0.0.5'])).toBe('https://10.0.0.5:8443')
  })

  test('NAT slirp guest IPs are not linked; This Device uses hostfwd localhost', () => {
    const http = port({ address: '0.0.0.0', port: 80, label: 'HTTP' })
    const https = port({ address: '0.0.0.0', port: 8443, label: 'HTTPS' })
    const slirp = ['10.0.2.15']
    const natThisDevice = {
      isMember: false,
      guestIpsReachable: false,
      portForwards: [
        { protocol: 'tcp' as const, hostPort: 8080, guestPort: 80 },
        { protocol: 'tcp' as const, hostPort: 18443, guestPort: 8443 },
      ],
    }
    expect(guestListeningPortHref(http, slirp)).toBeNull()
    expect(guestListeningPortHref(http, slirp, {
      isMember: false,
      guestIpsReachable: false,
      portForwards: [],
    })).toBeNull()
    expect(guestListeningPortHref(http, slirp, natThisDevice)).toBe('http://127.0.0.1:8080')
    expect(guestListeningPortHref(https, slirp, natThisDevice)).toBe('https://127.0.0.1:18443')
    expect(guestListeningPortHref(http, slirp, {
      isMember: true,
      guestIpsReachable: false,
      portForwards: natThisDevice.portForwards,
    })).toBeNull()
  })

  test('only common ports are shown', () => {
    expect(isPublishedGuestPort(port({ port: 22 }))).toBe(true)
    expect(isPublishedGuestPort(port({ port: 8081 }))).toBe(true)
    expect(isPublishedGuestPort(port({ port: 111 }))).toBe(false)
    expect(isPublishedGuestPort(port({ port: 5353 }))).toBe(false)
  })

  test('probed HTTP scheme is a browser URL even without a well-known label', () => {
    expect(guestListeningPortHref(port({
      address: '10.0.0.5',
      port: 8081,
      scheme: 'http',
      label: 'Dev',
    }), ['10.0.0.5'])).toBe('http://10.0.0.5:8081')
    expect(guestListeningPortHref(port({
      address: '10.0.0.5',
      port: 8080,
      label: 'HTTP',
      scheme: null,
    }), ['10.0.0.5'])).toBeNull()
    expect(guestListeningPortHref(port({
      address: '10.0.0.5',
      port: 8080,
      label: 'HTTP',
    }), ['10.0.0.5'])).toBe('http://10.0.0.5:8080')
  })

  test('SSH is labeled but not a browser URL', () => {
    expect(guestListeningPortHref(port({
      address: '0.0.0.0',
      port: 22,
      label: 'SSH',
    }), ['10.0.0.5'])).toBeNull()
  })

  test('null means unavailable and empty means none at the type layer', () => {
    const unavailable: GuestListeningPort[] | null = null
    const none: GuestListeningPort[] = []
    expect(unavailable).toBeNull()
    expect(none).toEqual([])
  })
})

describe('suggest NAT hostfwd (PAS-228)', () => {
  const ssh = port({ address: '0.0.0.0', port: 22, label: 'SSH' })
  const http = port({ address: '0.0.0.0', port: 80, label: 'HTTP' })
  const loopbackHttp = port({
    address: '127.0.0.1',
    port: 80,
    scope: 'internal',
    label: 'HTTP',
  })

  test('This Device NAT publishes guest port when that host port is free', () => {
    expect(suggestPublishNatHostfwd(http, {
      isMember: false,
      networkMode: 'nat',
      portForwards: [],
      occupiedHostPorts: [],
    })).toEqual({ protocol: 'tcp', hostPort: 80, guestPort: 80 })
    expect(suggestPublishNatHostfwd(ssh, {
      isMember: false,
      networkMode: null,
      portForwards: [],
      occupiedHostPorts: [2222],
    })).toEqual({ protocol: 'tcp', hostPort: 22, guestPort: 22 })
  })

  test('occupied guest port takes the next free host port', () => {
    expect(nextFreeHostPort(80, [80, 81])).toBe(82)
    expect(suggestPublishNatHostfwd(http, {
      isMember: false,
      networkMode: 'nat',
      portForwards: [{ protocol: 'tcp', hostPort: 8080, guestPort: 8080 }],
      occupiedHostPorts: [80, 8080],
    })).toEqual({ protocol: 'tcp', hostPort: 81, guestPort: 80 })
  })

  test('matching hostfwd, loopback, member, bridged, and isolated hide the control', () => {
    const forwarded = {
      isMember: false,
      networkMode: 'nat' as const,
      portForwards: [{ protocol: 'tcp' as const, hostPort: 8080, guestPort: 80 }],
      occupiedHostPorts: [8080],
    }
    expect(suggestPublishNatHostfwd(http, forwarded)).toBeNull()
    expect(suggestPublishNatHostfwd(loopbackHttp, {
      isMember: false,
      networkMode: 'nat',
      portForwards: [],
      occupiedHostPorts: [],
    })).toBeNull()
    expect(suggestPublishNatHostfwd(http, {
      isMember: true,
      networkMode: 'nat',
      portForwards: [],
      occupiedHostPorts: [],
    })).toBeNull()
    expect(suggestPublishNatHostfwd(http, {
      isMember: false,
      networkMode: 'bridged',
      portForwards: [],
      occupiedHostPorts: [],
    })).toBeNull()
    expect(suggestPublishNatHostfwd(http, {
      isMember: false,
      networkMode: 'isolated',
      portForwards: [],
      occupiedHostPorts: [],
    })).toBeNull()
    expect(suggestPublishNatHostfwd(http, {
      isMember: false,
      networkMode: 'unresolved',
      portForwards: [],
      occupiedHostPorts: [],
    })).toBeNull()
  })

  test('unpublished ports are not offered', () => {
    expect(suggestPublishNatHostfwd(port({ address: '0.0.0.0', port: 111 }), {
      isMember: false,
      networkMode: 'nat',
      portForwards: [],
      occupiedHostPorts: [],
    })).toBeNull()
  })

  test('isolated leftover hostfwd is not a NAT claim', () => {
    expect(claimedNatTcpHostPorts(
      [
        { networkId: 'net-nat', portForwards: [{ protocol: 'tcp', hostPort: 2222, guestPort: 22 }] },
        { networkId: 'net-iso', portForwards: [{ protocol: 'tcp', hostPort: 80, guestPort: 80 }] },
        { networkId: null, portForwards: [{ protocol: 'tcp', hostPort: 443, guestPort: 443 }] },
      ],
      [
        { id: 'net-nat', mode: 'nat' },
        { id: 'net-iso', mode: 'isolated' },
      ],
    )).toEqual([2222, 443])
  })
})

function guest(partial: Partial<GuestInfo> & Pick<GuestInfo, 'listeningPorts'>): GuestInfo {
  return {
    available: true,
    ipAddresses: ['10.0.0.5'],
    macAddress: null,
    ipSource: 'guest-agent',
    hostname: 'guest',
    osName: 'Ubuntu',
    osVersion: '24.04',
    osId: 'ubuntu',
    kernelVersion: null,
    kernelRelease: null,
    machine: null,
    timezone: null,
    timezoneOffset: null,
    users: null,
    filesystems: null,
    ...partial,
  }
}

describe('guestListServiceChips (PAS-232)', () => {
  test('unavailable listeners stay null so the list can keep hostfwd chips', () => {
    expect(guestListServiceChips({
      guest: guest({ listeningPorts: null }),
      isMember: false,
      guestIpsReachable: true,
      portForwards: [],
    })).toBeNull()
    expect(guestListServiceChips({
      guest: null,
      isMember: false,
      guestIpsReachable: true,
      portForwards: [],
    })).toBeNull()
  })

  test('empty listeners are none and do not invent ports', () => {
    expect(guestListServiceChips({
      guest: guest({ listeningPorts: [] }),
      isMember: false,
      guestIpsReachable: true,
      portForwards: [{ protocol: 'tcp', hostPort: 2222, guestPort: 22 }],
    })).toEqual([])
  })

  test('list chips are SSH and HTTP only; loopback and Dev stay off the row', () => {
    const chips = guestListServiceChips({
      guest: guest({
        listeningPorts: [
          port({ port: 22, label: 'SSH' }),
          port({ port: 80, label: 'HTTP' }),
          port({ port: 443, label: 'HTTPS' }),
          port({ port: 3000, label: 'Dev' }),
          port({ port: 3306, label: 'MySQL' }),
          port({ address: '127.0.0.1', port: 8080, scope: 'internal', label: 'HTTP' }),
        ],
      }),
      isMember: false,
      guestIpsReachable: true,
      portForwards: [],
    })
    expect(chips?.map((c) => c.label)).toEqual(['SSH', 'HTTP', 'HTTPS'])
    expect(chips?.find((c) => c.label === 'SSH')?.href).toBeNull()
    expect(chips?.find((c) => c.label === 'HTTP')?.href).toBe('http://10.0.0.5')
    expect(chips?.find((c) => c.label === 'HTTPS')?.href).toBe('https://10.0.0.5')
    expect(chips?.find((c) => c.label === 'SSH')?.copyText).toBe('10.0.0.5:22')
  })

  test('bridged guest IP is the HTTP href; This Device NAT uses hostfwd; members never get localhost', () => {
    const http = port({ port: 80, label: 'HTTP' })
    const ssh = port({ port: 22, label: 'SSH' })
    const forwards = [
      { protocol: 'tcp' as const, hostPort: 8080, guestPort: 80 },
      { protocol: 'tcp' as const, hostPort: 2222, guestPort: 22 },
    ]
    const bridged = guestListServiceChips({
      guest: guest({ listeningPorts: [ssh, http] }),
      isMember: false,
      guestIpsReachable: true,
      portForwards: forwards,
    })
    expect(bridged?.find((c) => c.label === 'HTTP')?.href).toBe('http://10.0.0.5')

    const natThisDevice = guestListServiceChips({
      guest: guest({ ipAddresses: ['10.0.2.15'], listeningPorts: [ssh, http] }),
      isMember: false,
      guestIpsReachable: false,
      portForwards: forwards,
    })
    expect(natThisDevice?.find((c) => c.label === 'HTTP')?.href).toBe('http://127.0.0.1:8080')
    expect(natThisDevice?.find((c) => c.label === 'SSH')?.href).toBeNull()
    expect(natThisDevice?.find((c) => c.label === 'SSH')?.copyText).toBe('127.0.0.1:2222')

    const memberNat = guestListServiceChips({
      guest: guest({ ipAddresses: ['10.0.2.15'], listeningPorts: [ssh, http] }),
      isMember: true,
      guestIpsReachable: false,
      portForwards: forwards,
    })
    expect(memberNat?.find((c) => c.label === 'HTTP')?.href).toBeNull()
    expect(memberNat?.find((c) => c.label === 'SSH')?.copyText).toBe('SSH')
    expect(JSON.stringify(memberNat)).not.toContain('127.0.0.1')
    expect(JSON.stringify(memberNat)).not.toContain('localhost')
  })

  test('unknown network mode follows operator-reachable guest IPs, never slirp', () => {
    expect(guestIpsReachableFromNetwork('bridged', ['10.0.2.15'])).toBe(true)
    expect(guestIpsReachableFromNetwork('nat', ['192.168.1.10'])).toBe(false)
    expect(guestIpsReachableFromNetwork('isolated', ['192.168.1.10'])).toBe(false)
    expect(guestIpsReachableFromNetwork(null, ['192.168.1.10'])).toBe(true)
    expect(guestIpsReachableFromNetwork(undefined, ['10.0.2.15'])).toBe(false)
  })

  test('duplicate HTTP listeners collapse to one chip preferring port 80', () => {
    const chips = guestListServiceChips({
      guest: guest({
        listeningPorts: [
          port({ port: 8080, label: 'HTTP' }),
          port({ address: '::', port: 80, label: 'HTTP' }),
        ],
      }),
      isMember: false,
      guestIpsReachable: true,
      portForwards: [],
    })
    expect(chips).toEqual([{
      key: 'HTTP-80',
      label: 'HTTP',
      href: 'http://10.0.0.5',
      copyText: '10.0.0.5',
    }])
