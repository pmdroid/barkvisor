import { describe, expect, test } from 'bun:test'
import {
  canCallDeviceAPI,
  canFetchDeviceWorkloads,
  deviceCapabilitiesPath,
  devicePath,
  deviceTaskPath,
  deviceTemplateDeployPath,
  deviceTemplateDryRunPath,
  deviceTemplatesPath,
  deviceVmActionPath,
  deviceVmPath,
  deviceVmsBasePath,
  isSelfDevice,
  resolveSelectedDevice,
  selectedHostIsLive,
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
    expect(deviceVmActionPath(member, 'vm-9', 'restart')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/restart',
    )
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
    expect(deviceVmsBasePath(self)).toBe('/vms')

    expect(deviceTemplatesPath(member)).toBe('/home/devices/peer%2F1/v1/templates')
    expect(deviceTemplateDeployPath(member)).toBe('/home/devices/peer%2F1/v1/templates/deploy')
    expect(deviceTemplateDryRunPath(member, 'tpl/1')).toBe(
      '/home/devices/peer%2F1/v1/templates/tpl%2F1/deploy/dry-run',
    )
    expect(deviceTaskPath(member, 'task-9')).toBe('/home/devices/peer%2F1/v1/tasks/task-9')
    expect(deviceCapabilitiesPath(member)).toBe('/home/devices/peer%2F1/v1/system/capabilities')
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
})
