/** Home proxy paths for a Device's Workloads (PAS-52 remainder).
 *  Members go through /home/devices/:id/v1/*; self stays on local /vms. */

export type DeviceApiTarget = {
  hostId: string
  role?: string | null
  reachability?: string | null
}

export function isSelfDevice(device: DeviceApiTarget): boolean {
  return device.role === 'self'
}

/** Members must be reachable before we call them. Self always uses local SQLite. */
export function canFetchDeviceWorkloads(device: DeviceApiTarget): boolean {
  if (isSelfDevice(device)) return true
  return device.reachability === 'ok'
}

export function deviceVmsBasePath(device: DeviceApiTarget): string {
  if (isSelfDevice(device)) return '/vms'
  return `/home/devices/${encodeURIComponent(device.hostId)}/v1/vms`
}

export function deviceVmPath(device: DeviceApiTarget, vmId: string): string {
  return `${deviceVmsBasePath(device)}/${encodeURIComponent(vmId)}`
}

export function deviceVmActionPath(
  device: DeviceApiTarget,
  vmId: string,
  action: 'start' | 'stop' | 'restart',
): string {
  return `${deviceVmPath(device, vmId)}/${action}`
}
