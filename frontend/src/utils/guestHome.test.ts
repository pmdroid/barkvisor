import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { GuestInfo, PortForwardRule } from '../api/types'
import {
  canFetchGuestInfo,
  deviceGuestInfoPath,
  guestInfoFetchPath,
  guestInfoIfRunning,
  guestIpPortsView,
  guestOsLabel,
  guestPrimaryIp,
  guestServiceHref,
  guestServiceLabel,
} from './guestHome'

const here = dirname(fileURLToPath(import.meta.url))
const self = { hostId: 'desk-1', role: 'self', reachability: 'ok' }
const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }
const down = { hostId: 'peer-2', role: 'member', reachability: 'unreachable' }

const ubuntu: GuestInfo = {
  available: true,
  ipAddresses: ['10.0.0.12'],
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
}

const sshForward: PortForwardRule = {
  protocol: 'tcp',
  hostPort: 2222,
  guestPort: 22,
}

describe('guestHome (PAS-201)', () => {
  test('self stays on local guest-info; members use the Home proxy', () => {
    expect(deviceGuestInfoPath(self, 'vm-9')).toBe('/vms/vm-9/guest-info')
    expect(deviceGuestInfoPath(member, 'vm-9')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/guest-info',
    )
    expect(deviceGuestInfoPath(member, 'vm/9')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm%2F9/guest-info',
    )
    expect(deviceGuestInfoPath(member, 'vm-9')).not.toContain('cluster')
    expect(deviceGuestInfoPath(member, 'vm-9')).not.toContain('targetHostId')
  })

  test('unreachable members are not fetched; self still is', () => {
    expect(canFetchGuestInfo(self)).toBe(true)
    expect(canFetchGuestInfo({ ...self, reachability: 'unreachable' })).toBe(true)
    expect(canFetchGuestInfo(member)).toBe(true)
    expect(canFetchGuestInfo(down)).toBe(false)
    expect(guestInfoFetchPath(down, 'vm-9', 'running')).toBeNull()
    expect(guestInfoFetchPath(member, 'vm-9', 'stopped')).toBeNull()
    expect(guestInfoFetchPath(null, 'vm-9', 'running')).toBeNull()
    expect(guestInfoFetchPath(member, 'vm-9', 'running')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/guest-info',
    )
    expect(guestInfoFetchPath(self, 'vm-9', 'running')).toBe('/vms/vm-9/guest-info')
  })

  test('OS and IP come from guest-info when present', () => {
    expect(guestOsLabel(ubuntu, 'linux')).toBe('Ubuntu 24.04')
    expect(guestOsLabel({ ...ubuntu, osVersion: null }, 'linux')).toBe('Ubuntu')
    expect(guestOsLabel(null, 'linux')).toBe('Linux')
    expect(guestOsLabel(null, 'windows11')).toBe('Windows')
    expect(guestOsLabel(ubuntu, 'linux', false)).toBe('—')
    expect(guestOsLabel(null, 'linux', false)).toBe('—')
    expect(guestPrimaryIp(ubuntu)).toBe('10.0.0.12')
    expect(guestPrimaryIp(null)).toBeNull()
    expect(guestPrimaryIp({ ...ubuntu, ipAddresses: [] })).toBeNull()
    expect(guestPrimaryIp({
      ...ubuntu,
      available: false,
      ipAddresses: ['10.0.2.15'],
      ipSource: 'nat-default',
      osName: null,
      osVersion: null,
    })).toBeNull()
    expect(guestServiceLabel('10.0.0.12', 22)).toBe('10.0.0.12:22')
    expect(guestServiceLabel('10.0.0.12', 80)).toBe('10.0.0.12')
    expect(guestServiceHref('10.0.0.12', 443)).toBe('https://10.0.0.12')
    expect(guestServiceHref('10.0.0.12', 8080)).toBe('http://10.0.0.12:8080')
  })

  test('member IP/ports stay empty when unreachable; never localhost', () => {
    expect(guestIpPortsView({
      reachable: false,
      isMember: true,
      isLocalNat: false,
      guest: ubuntu,
      portForwards: [sshForward],
    })).toEqual({ kind: 'empty' })

    expect(guestIpPortsView({
      reachable: true,
      isMember: true,
      isLocalNat: true,
      guest: ubuntu,
      portForwards: [sshForward],
    })).toEqual({
      kind: 'bridged-ip',
      ip: '10.0.0.12',
      links: [{
        label: '10.0.0.12:22',
        copyText: '10.0.0.12:22',
        href: 'http://10.0.0.12:22',
      }],
    })

    expect(guestIpPortsView({
      reachable: true,
      isMember: true,
      isLocalNat: true,
      guest: null,
      portForwards: [sshForward],
    })).toEqual({ kind: 'port-map', labels: ['2222→22'] })

    expect(guestIpPortsView({
      reachable: true,
      isMember: true,
      isLocalNat: false,
      guest: null,
      portForwards: [],
    })).toEqual({ kind: 'empty' })

    const natPlaceholder: GuestInfo = {
      ...ubuntu,
      available: false,
      ipAddresses: ['10.0.2.15'],
      ipSource: 'nat-default',
      osName: null,
      osVersion: null,
    }
    expect(guestIpPortsView({
      reachable: true,
      isMember: true,
      isLocalNat: true,
      guest: natPlaceholder,
      portForwards: [sshForward],
    })).toEqual({ kind: 'port-map', labels: ['2222→22'] })
    expect(guestIpPortsView({
      reachable: true,
      isMember: true,
      isLocalNat: true,
      guest: natPlaceholder,
      portForwards: [],
    })).toEqual({ kind: 'empty' })
  })

  test('self NAT still shows localhost host ports; bridged uses guest IP', () => {
    expect(guestIpPortsView({
      reachable: true,
      isMember: false,
      isLocalNat: true,
      guest: null,
      portForwards: [sshForward],
    })).toEqual({ kind: 'nat-localhost', hostPorts: [2222] })

    expect(guestIpPortsView({
      reachable: true,
      isMember: false,
      isLocalNat: false,
      guest: ubuntu,
      portForwards: [],
    })).toEqual({
      kind: 'bridged-ip',
      ip: '10.0.0.12',
      links: [{ label: '10.0.0.12', copyText: '10.0.0.12' }],
    })
  })

  test('list and member detail both use the same helper', () => {
    const list = readFileSync(join(here, '../views/VMListView.vue'), 'utf8')
    const detail = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')
    expect(list).toContain("from '../utils/guestHome'")
    expect(detail).toContain("from '../utils/guestHome'")
    expect(list).toContain('guestInfoFetchPath')
    expect(detail).toContain('guestInfoFetchPath')
    expect(list).toContain('guestInfoIfRunning')
    expect(list).toContain('guestIpPortsView')
    expect(detail).toContain('guestOsLabel')
    expect(detail).toContain('{{ memberOsLabel }}')
    expect(detail).not.toContain('v-if="guestInfo?.osName"')
    expect(list).not.toMatch(/api\.get\(`\/vms\/\$\{[^}]+}\/guest-info`\)/)
    expect(detail).not.toMatch(/api\.get\(`\/vms\/\$\{[^}]+}\/guest-info`\)/)
    expect(detail).not.toMatch(/if \(isMemberDetail\.value\) \{ guestInfo\.value = null; return \}/)
    expect(detail).toContain('detail-label">OS')
    expect(detail).toContain('detail-label">IP Address')
  })

  test('member detail poll waits for refresh and drops stale guest-info', () => {
    const detail = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')
    const fetchFn = detail.match(/async function fetchGuestInfo\(\) \{[\s\S]*?\n\}/)?.[0] ?? ''
    expect(fetchFn).toContain('detailLoadVersion')
    expect(fetchFn).toContain('vmId.value')
    expect(fetchFn).toContain('hostId.value')
    expect(fetchFn).toContain('stillCurrent')
    expect(fetchFn).toMatch(/guestInfo\.value = data/)
    expect(detail).toMatch(
      /refreshOne\([^)]+\)\.then\(\(\) => \{[\s\S]*?fetchGuestInfo\(\)[\s\S]*?\}\)\.catch\(\(e\) => \{/,
    )
    expect(detail).not.toMatch(/void fetchGuestInfo\(\)/)
    expect(detail).not.toMatch(
      /refreshOne\([^)]+\)\.catch\([\s\S]*?\}\)\s*void fetchGuestInfo\(\)/,
    )
  })

  test('cached guest-info is ignored unless the Workload is running', () => {
    expect(guestInfoIfRunning(ubuntu, 'running')).toEqual(ubuntu)
    expect(guestInfoIfRunning(ubuntu, 'stopped')).toBeNull()
    expect(guestInfoIfRunning(ubuntu, 'starting')).toBeNull()
    expect(guestInfoIfRunning(ubuntu, undefined)).toBeNull()
    expect(guestInfoIfRunning(null, 'running')).toBeNull()
    expect(guestOsLabel(guestInfoIfRunning(ubuntu, 'stopped'), 'linux')).toBe('Linux')
    expect(guestIpPortsView({
      reachable: true,
      isMember: true,
      isLocalNat: false,
      guest: guestInfoIfRunning(ubuntu, 'stopped'),
      portForwards: [sshForward],
    })).toEqual({ kind: 'port-map', labels: ['2222→22'] })
    expect(guestIpPortsView({
      reachable: true,
      isMember: false,
      isLocalNat: false,
      guest: guestInfoIfRunning(ubuntu, 'stopped'),
      portForwards: [],
    })).toEqual({ kind: 'empty' })
  })

  test('member detail lifecycle actions refresh guest-info', () => {
    const detail = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')
    const startFn = detail.match(/async function startWorkload\(\) \{[\s\S]*?\n\}/)?.[0] ?? ''
    const restartFn = detail.match(/async function restartWorkload\(\) \{[\s\S]*?\n\}/)?.[0] ?? ''
    const stopFn = detail.match(/async function confirmStop\(\) \{[\s\S]*?\n\}/)?.[0] ?? ''
    expect(startFn).toContain('homeWorkloads.start')
    expect(startFn).toContain('guestInfo.value = null')
    expect(startFn).toContain('fetchGuestInfo()')
    expect(restartFn).toContain('homeWorkloads.restart')
    expect(restartFn).toContain('guestInfo.value = null')
    expect(restartFn).toContain('fetchGuestInfo()')
    expect(stopFn).toContain('refreshWorkload()')
    expect(stopFn).toContain('guestInfo.value = null')
    expect(stopFn).toContain('fetchGuestInfo()')
  })
})
