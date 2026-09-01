import { describe, expect, test } from 'bun:test'
import {
  canCallDeviceAPI,
  canFetchDeviceWorkloads,
  deviceAboutPath,
  deviceDoctorPath,
  deviceBridgesPath,
  deviceCapabilitiesPath,
  deviceDiskPath,
  deviceDiskResizePath,
  deviceDiskSummaryPath,
  deviceDiskUsagePath,
  deviceBlockDevicesPath,
  deviceBrowsePath,
  deviceDiskSettingsPath,
  deviceDisksPath,
  deviceGuestInfoPath,
  deviceInterfacesPath,
  deviceNetworkPath,
  deviceNetworksPath,
  devicePath,
  deviceStatsHistoryPath,
  deviceTaskPath,
  deviceRepositoriesPath,
  deviceRepositorySyncPath,
  deviceTemplateDeployPath,
  deviceTemplateDryRunPath,
  deviceTemplatesPath,
  deviceVmActionPath,
  deviceVmSessionPath,
  deviceVmConsolePath,
  deviceVmPath,
  deviceVmSpecPath,
  deviceVmVncPath,
  deviceVmsBasePath,
  deviceWsTicketPath,
  defaultPickedHostId,
  deviceImagePath,
  isSelfDevice,
  owningMemberDevice,
  resolveSelectedDevice,
  selectedHostIsLive,
  usesLocalDeviceInventory,
} from './homeDeviceApi'

const self = { hostId: 'desk-1', role: 'self', reachability: 'ok' }
const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }
const down = { hostId: 'peer-2', role: 'member', reachability: 'unreachable' }

describe('homeDeviceApi (PAS-52)', () => {
  test('self stays on local /vms; members use the Home proxy', () => {
    expect(isSelfDevice(self)).toBe(true)
    expect(isSelfDevice(member)).toBe(false)
    expect(deviceVmsBasePath(self)).toBe('/vms')
    expect(deviceVmsBasePath(member)).toBe('/home/devices/peer%2F1/v1/vms')
    expect(deviceVmPath(self, 'vm-9')).toBe('/vms/vm-9')
    expect(deviceVmActionPath(member, 'vm-9', 'start')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/start',
    )
    expect(deviceVmActionPath(self, 'vm-9', 'stop')).toBe('/vms/vm-9/stop')
    expect(deviceVmSessionPath(self, 'vm-9', 'resume')).toBe('/vms/vm-9/session/resume')
    expect(deviceVmSessionPath(member, 'vm-9', 'burn')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/session/burn',
    )
    expect(deviceVmActionPath(member, 'vm-9', 'restart')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/restart',
    )
    expect(deviceWsTicketPath(self)).toBe('/auth/ws-ticket')
    expect(deviceWsTicketPath(member)).toBe('/home/devices/peer%2F1/v1/auth/ws-ticket')
    expect(deviceVmVncPath(member, 'vm-9')).toBe('/home/devices/peer%2F1/v1/vms/vm-9/vnc')
    expect(deviceVmConsolePath(self, 'vm-9')).toBe('/vms/vm-9/console')
  })

  test('unreachable members are not fetched; self still is', () => {
    expect(canFetchDeviceWorkloads(self)).toBe(true)
    expect(canFetchDeviceWorkloads({ ...self, reachability: 'unreachable' })).toBe(true)
    expect(canFetchDeviceWorkloads(member)).toBe(true)
    expect(canFetchDeviceWorkloads(down)).toBe(false)
    expect(canCallDeviceAPI(down)).toBe(false)
  })
})

describe('homeDeviceApi (PAS-34 remainder)', () => {
  test('self stays on local paths; members use the Home proxy', () => {
    expect(devicePath(self, '/templates')).toBe('/templates')
    expect(deviceTemplatesPath(self)).toBe('/templates')
    expect(deviceTemplateDeployPath(self)).toBe('/templates/deploy')
    expect(deviceTemplateDryRunPath(self, 'tpl/1')).toBe('/templates/tpl%2F1/deploy/dry-run')
    expect(deviceTaskPath(self, 'task-9')).toBe('/tasks/task-9')
    expect(deviceCapabilitiesPath(self)).toBe('/system/capabilities')
    expect(deviceAboutPath(self)).toBe('/system/about')
    expect(deviceDoctorPath(self)).toBe('/system/doctor')
    expect(deviceVmsBasePath(self)).toBe('/vms')

    expect(deviceRepositoriesPath(self)).toBe('/repositories')
    expect(deviceRepositorySyncPath(self, 'repo-1')).toBe('/repositories/repo-1/sync')
    expect(deviceTemplatesPath(member)).toBe('/home/devices/peer%2F1/v1/templates')
    expect(deviceRepositoriesPath(member)).toBe('/home/devices/peer%2F1/v1/repositories')
    expect(deviceRepositorySyncPath(member, 'repo/1')).toBe(
      '/home/devices/peer%2F1/v1/repositories/repo%2F1/sync',
    )
    expect(deviceTemplateDeployPath(member)).toBe('/home/devices/peer%2F1/v1/templates/deploy')
    expect(deviceTemplateDryRunPath(member, 'tpl/1')).toBe(
      '/home/devices/peer%2F1/v1/templates/tpl%2F1/deploy/dry-run',
    )
    expect(deviceTaskPath(member, 'task-9')).toBe('/home/devices/peer%2F1/v1/tasks/task-9')
    expect(deviceCapabilitiesPath(member)).toBe('/home/devices/peer%2F1/v1/system/capabilities')
    expect(deviceAboutPath(member)).toBe('/home/devices/peer%2F1/v1/system/about')
    expect(deviceDoctorPath(member)).toBe('/home/devices/peer%2F1/v1/system/doctor')
    expect(deviceDoctorPath(member)).not.toContain('cluster')
    expect(devicePath(member, '/images')).toBe('/home/devices/peer%2F1/v1/images')
  })

  test('a stale hostId does not fall back to self', () => {
    const byId = (id: string) => (id === member.hostId ? member : id === self.hostId ? self : null)
    expect(resolveSelectedDevice(member.hostId, byId, self)).toBe(member)
    expect(resolveSelectedDevice('gone', byId, self)).toBeNull()
    expect(resolveSelectedDevice('', byId, self)).toBe(self)
    expect(selectedHostIsLive(member.hostId, byId)).toBe(true)
    expect(selectedHostIsLive('gone', byId)).toBe(false)
    expect(selectedHostIsLive('', byId)).toBe(true)
  })

  test('default pick is initial or self, never the first compatible peer', () => {
    expect(defaultPickedHostId('desk-1', 'desk-1')).toBe('desk-1')
    expect(defaultPickedHostId(undefined, 'desk-1')).toBe('desk-1')
    expect(defaultPickedHostId('', 'desk-1')).toBe('desk-1')
    expect(defaultPickedHostId(null, null)).toBe('')
    expect(usesLocalDeviceInventory(self)).toBe(true)
    expect(usesLocalDeviceInventory(member)).toBe(false)
    expect(usesLocalDeviceInventory(down)).toBe(false)
  })
})

describe('homeDeviceApi (PAS-202)', () => {
  test('GET/PATCH/start/stop/restart use devicePath, never a targetHostId body', () => {
    expect(deviceVmPath(self, 'vm-9')).toBe('/vms/vm-9')
    expect(deviceVmSpecPath(self, 'vm-9')).toBe('/vms/vm-9/spec')
    expect(devicePath(self, '/vms/vm-9')).toBe('/vms/vm-9')

    expect(devicePath(member, '/vms/vm-9')).toBe('/home/devices/peer%2F1/v1/vms/vm-9')
    expect(deviceVmPath(member, 'vm-9')).toBe('/home/devices/peer%2F1/v1/vms/vm-9')
    expect(deviceVmSpecPath(member, 'vm-9')).toBe('/home/devices/peer%2F1/v1/vms/vm-9/spec')
    expect(deviceVmActionPath(member, 'vm-9', 'start')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/start',
    )
    expect(deviceVmActionPath(member, 'vm-9', 'stop')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/stop',
    )
    expect(deviceVmActionPath(member, 'vm-9', 'restart')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/restart',
    )
    expect(devicePath(member, '/vms/vm-9')).not.toContain('targetHostId')
  })
})

describe('homeDeviceApi (PAS-201)', () => {
  test('guest-info uses devicePath, never a new Home API', () => {
    expect(deviceGuestInfoPath(self, 'vm-9')).toBe('/vms/vm-9/guest-info')
    expect(deviceGuestInfoPath(member, 'vm-9')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/guest-info',
    )
    expect(deviceGuestInfoPath(member, 'vm-9')).not.toContain('cluster')
  })
})

describe('homeDeviceApi (PAS-203)', () => {
  test('logs, metrics, USB, disks, and networks use devicePath', () => {
    expect(devicePath(self, '/logs')).toBe('/logs')
    expect(devicePath(member, '/logs')).toBe('/home/devices/peer%2F1/v1/logs')
    expect(devicePath(member, '/vms/vm-9/metrics')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/metrics',
    )
    expect(devicePath(member, '/system/usb-devices')).toBe(
      '/home/devices/peer%2F1/v1/system/usb-devices',
    )
    expect(devicePath(member, '/disks')).toBe('/home/devices/peer%2F1/v1/disks')
    expect(devicePath(member, '/networks')).toBe('/home/devices/peer%2F1/v1/networks')
    expect(devicePath(member, '/logs')).not.toContain('targetHostId')
  })
})

describe('homeDeviceApi (device about)', () => {
  test('self stays local; members use the Home proxy', () => {
    expect(deviceAboutPath(self)).toBe('/system/about')
    expect(deviceAboutPath(member)).toBe('/home/devices/peer%2F1/v1/system/about')
    expect(deviceAboutPath(member)).not.toContain('targetHostId')
    expect(canFetchDeviceWorkloads(down)).toBe(false)
  })
})

describe('homeDeviceApi (device name)', () => {
  test('self stays local; members hop PUT /system/device-name', () => {
    expect(devicePath(self, '/system/device-name')).toBe('/system/device-name')
    expect(devicePath(member, '/system/device-name')).toBe(
      '/home/devices/peer%2F1/v1/system/device-name',
    )
    expect(devicePath(member, '/system/device-name')).not.toContain('targetHostId')
    expect(canFetchDeviceWorkloads(down)).toBe(false)
  })
})

describe('homeDeviceApi (device stats history)', () => {
  test('self stays local; members use the Home proxy minutes query', () => {
    expect(deviceStatsHistoryPath(self)).toBe('/system/stats/history?minutes=30')
    expect(deviceStatsHistoryPath(member)).toBe(
      '/home/devices/peer%2F1/v1/system/stats/history?minutes=30',
    )
    expect(deviceStatsHistoryPath(member, 15)).toBe(
      '/home/devices/peer%2F1/v1/system/stats/history?minutes=15',
    )
    expect(deviceStatsHistoryPath(member)).not.toContain('targetHostId')
  })
})

describe('homeDeviceApi (PAS-218)', () => {
  test('disk list, usage, summary, and resize stay on devicePath', () => {
    expect(deviceDisksPath(self)).toBe('/disks')
    expect(deviceDiskPath(self, 'd-1')).toBe('/disks/d-1')
    expect(deviceDiskUsagePath(self, 'd-1')).toBe('/disks/d-1/usage')
    expect(deviceDiskResizePath(self, 'd-1')).toBe('/disks/d-1/resize')
    expect(deviceDiskSummaryPath(self)).toBe('/disks/summary')
    expect(deviceDiskSettingsPath(self)).toBe('/system/disk/settings')
    expect(deviceBrowsePath(self)).toBe('/system/browse')
    expect(deviceBrowsePath()).toBe('/system/browse')
    expect(deviceBlockDevicesPath(self)).toBe('/system/block-devices')

    expect(deviceDisksPath(member)).toBe('/home/devices/peer%2F1/v1/disks')
    expect(deviceDiskPath(member, 'd/1')).toBe('/home/devices/peer%2F1/v1/disks/d%2F1')
    expect(deviceDiskUsagePath(member, 'd/1')).toBe('/home/devices/peer%2F1/v1/disks/d%2F1/usage')
    expect(deviceDiskResizePath(member, 'd/1')).toBe('/home/devices/peer%2F1/v1/disks/d%2F1/resize')
    expect(deviceDiskSummaryPath(member)).toBe('/home/devices/peer%2F1/v1/disks/summary')
    expect(deviceDiskSettingsPath(member)).toBe('/home/devices/peer%2F1/v1/system/disk/settings')
    expect(deviceBrowsePath(member)).toBe('/home/devices/peer%2F1/v1/system/browse')
    expect(deviceBlockDevicesPath(member)).toBe('/home/devices/peer%2F1/v1/system/block-devices')
    expect(deviceDiskPath(member, 'd-1')).not.toContain('targetHostId')
  })
})

describe('homeDeviceApi (GH-459)', () => {
  test('Home-union image delete routes to the owning Device, never self', () => {
    const byId = (id: string) => (id === member.hostId ? member : id === self.hostId ? self : null)
    expect(owningMemberDevice(member.hostId, byId)).toBe(member)
    expect(owningMemberDevice(self.hostId, byId)).toBeNull()
    expect(owningMemberDevice(undefined, byId)).toBeNull()
    expect(owningMemberDevice('', byId)).toBeNull()
    expect(owningMemberDevice('gone', byId)).toBeNull()
    expect(deviceImagePath(member, 'img/1')).toBe('/home/devices/peer%2F1/v1/images/img%2F1')
    expect(deviceImagePath(self, 'img-1')).toBe('/images/img-1')
  })
})

describe('homeDeviceApi (PAS-216)', () => {
  test('network, interface, and bridge paths stay on devicePath', () => {
    expect(deviceNetworksPath(self)).toBe('/networks')
    expect(deviceNetworkPath(self, 'net-1')).toBe('/networks/net-1')
    expect(deviceInterfacesPath(self)).toBe('/system/interfaces')
    expect(deviceBridgesPath(self)).toBe('/system/bridges')

    expect(deviceNetworksPath(member)).toBe('/home/devices/peer%2F1/v1/networks')
    expect(deviceNetworkPath(member, 'net/1')).toBe('/home/devices/peer%2F1/v1/networks/net%2F1')
    expect(deviceInterfacesPath(member)).toBe('/home/devices/peer%2F1/v1/system/interfaces')
    expect(deviceBridgesPath(member)).toBe('/home/devices/peer%2F1/v1/system/bridges')
    expect(deviceNetworkPath(member, 'net-1')).not.toContain('targetHostId')
  })
})
