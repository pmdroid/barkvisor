import { describe, expect, test } from 'bun:test'
import {
  canFetchDeviceWorkloads,
  deviceVmActionPath,
  deviceVmPath,
  deviceVmsBasePath,
  isSelfDevice,
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
  })
})
