import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  canEditMemberHardware,
  deviceDiskUsagePath,
  deviceDisksPath,
  deviceLogsPath,
  deviceNetworksPath,
  deviceUsbDevicesPath,
  deviceVmMetricsPath,
  deviceVmUsbDevicePath,
  deviceVmUsbPath,
  disksInventoryFetchPath,
  hardwarePatchBody,
  isMemberControlTab,
  logsHistoryFetchPath,
  memberControlTabAllowed,
  memberNetworkForDetail,
  metricsHistoryFetchPath,
  networksInventoryFetchPath,
  shouldPollDeviceControl,
  usbInventoryFetchPath,
} from './editHome'

const here = dirname(fileURLToPath(import.meta.url))
const self = { hostId: 'desk-1', role: 'self', reachability: 'ok' }
const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }
const down = { hostId: 'peer-2', role: 'member', reachability: 'unreachable' }

describe('editHome (PAS-203)', () => {
  test('remaining control uses devicePath, never a new Home API', () => {
    expect(deviceLogsPath(self)).toBe('/logs')
    expect(deviceLogsPath(member)).toBe('/home/devices/peer%2F1/v1/logs')
    expect(deviceVmMetricsPath(self, 'vm-9')).toBe('/vms/vm-9/metrics')
    expect(deviceVmMetricsPath(member, 'vm-9')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/metrics',
    )
    expect(deviceUsbDevicesPath(member)).toBe(
      '/home/devices/peer%2F1/v1/system/usb-devices',
    )
    expect(deviceVmUsbPath(member, 'vm-9')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/usb',
    )
    expect(deviceVmUsbDevicePath(member, 'vm-9', 'dead:beef')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/usb/dead%3Abeef',
    )
    expect(deviceDisksPath(member)).toBe('/home/devices/peer%2F1/v1/disks')
    expect(deviceDiskUsagePath(member, 'd/1')).toBe(
      '/home/devices/peer%2F1/v1/disks/d%2F1/usage',
    )
    expect(deviceNetworksPath(member)).toBe('/home/devices/peer%2F1/v1/networks')
    expect(deviceLogsPath(member)).not.toContain('cluster')
    expect(deviceVmUsbPath(member, 'vm-9')).not.toContain('targetHostId')
  })

  test('unreachable members are not fetched; self still is', () => {
    expect(canEditMemberHardware(self)).toBe(true)
    expect(canEditMemberHardware({ ...self, reachability: 'unreachable' })).toBe(true)
    expect(canEditMemberHardware(member)).toBe(true)
    expect(canEditMemberHardware(down)).toBe(false)
    expect(canEditMemberHardware(null)).toBe(false)
    expect(logsHistoryFetchPath(down)).toBeNull()
    expect(metricsHistoryFetchPath(down, 'vm-9', 'running')).toBeNull()
    expect(metricsHistoryFetchPath(member, 'vm-9', 'stopped')).toBeNull()
    expect(usbInventoryFetchPath(down)).toBeNull()
    expect(disksInventoryFetchPath(down)).toBeNull()
    expect(networksInventoryFetchPath(down)).toBeNull()
    expect(logsHistoryFetchPath(member)).toBe('/home/devices/peer%2F1/v1/logs')
    expect(metricsHistoryFetchPath(member, 'vm-9', 'running')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/metrics',
    )
    expect(logsHistoryFetchPath(self)).toBe('/logs')
  })

  test('members poll JSON; self may stream', () => {
    expect(shouldPollDeviceControl(self)).toBe(false)
    expect(shouldPollDeviceControl(member)).toBe(true)
    expect(shouldPollDeviceControl(down)).toBe(true)
    expect(shouldPollDeviceControl(null)).toBe(false)
  })

  test('member tabs are overview, metrics, and logs — never console or VNC', () => {
    expect(isMemberControlTab('overview')).toBe(true)
    expect(isMemberControlTab('metrics')).toBe(true)
    expect(isMemberControlTab('logs')).toBe(true)
    expect(isMemberControlTab('console')).toBe(false)
    expect(isMemberControlTab('vnc')).toBe(false)
    expect(memberControlTabAllowed('overview', 'stopped')).toBe(true)
    expect(memberControlTabAllowed('logs', 'stopped')).toBe(true)
    expect(memberControlTabAllowed('metrics', 'running')).toBe(true)
    expect(memberControlTabAllowed('metrics', 'stopped')).toBe(false)
    expect(memberControlTabAllowed('console', 'running')).toBe(false)
    expect(memberControlTabAllowed('vnc', 'running')).toBe(false)
  })

  test('member network comes from that Device inventory, not Home', () => {
    const nat = { id: 'net-orb', name: 'NAT', mode: 'nat', isDefault: true }
    const br = { id: 'net-br', name: 'LAN', mode: 'bridged', isDefault: false }
    expect(memberNetworkForDetail('net-br', [nat, br])).toEqual(br)
    expect(memberNetworkForDetail(null, [nat, br])).toEqual(nat)
    expect(memberNetworkForDetail('missing', [nat, br])).toBeNull()
  })

  test('hardware PATCH drops targetHostId', () => {
    expect(hardwarePatchBody({
      cpuCount: 2,
      memoryMB: 1024,
      targetHostId: 'foreign',
    })).toEqual({ cpuCount: 2, memoryMB: 1024 })
  })

  test('member detail uses editHome and polls instead of Upgrade', () => {
    const detail = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')
    const logs = readFileSync(join(here, '../stores/logs.ts'), 'utf8')
    const logsPanel = readFileSync(join(here, '../components/LogsPanel.vue'), 'utf8')
    const metrics = readFileSync(join(here, '../stores/metrics.ts'), 'utf8')
    expect(detail).toContain("from '../utils/editHome'")
    expect(detail).toContain('isMemberControlTab')
    expect(detail).toContain('memberControlTabAllowed')
    expect(detail).toContain('networkId: editDraft.value.networkId || vm.value?.networkId || null')
    expect(detail).toContain('usbInventoryFetchPath')
    expect(detail).toContain('disksInventoryFetchPath')
    expect(detail).toContain('networksInventoryFetchPath')
    expect(detail).toContain("tab === 'logs'")
    expect(detail).toContain(':device="isMemberDetail ? memberDevice : undefined"')
    expect(detail).toContain('homeWorkloads.attachUSB')
    expect(detail).toContain('homeWorkloads.detachUSB')
    expect(detail).toContain('!isMemberDetail && tab === \'console\'')
    expect(detail).toContain('!isMemberDetail && tab === \'vnc\'')
    expect(detail).toContain('usbInventoryFetchPath(memberDevice.value)')
    expect(detail).toContain("api.get('/system/usb-devices')")
    expect(detail).toMatch(/if \(isMemberDetail\.value\) \{[\s\S]*usbInventoryFetchPath/)
    expect(logs).toContain('shouldPollDeviceControl')
    expect(logs).toContain('logsHistoryFetchPath')
    expect(logs).toContain('if (!path) return false')
    expect(logsPanel).toContain('if (store.startTail(props.device))')
    expect(metrics).toContain('shouldPollDeviceControl')
    expect(metrics).toContain('metricsHistoryFetchPath')
    expect(metrics).not.toMatch(/fetch\(`\/api\/vms\/\$\{vmId\}\/metrics/)
  })
})
