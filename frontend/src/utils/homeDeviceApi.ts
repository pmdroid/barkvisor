/** Home proxy paths for a Device (PAS-52 / PAS-34).
 *  Members go through /home/devices/:id/v1/*; self stays on local /api paths. */

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

/** If a hostId was picked, never fall back to self (PAS-34). */
export function resolveSelectedDevice<T extends DeviceApiTarget>(
  selectedHostId: string,
  lookup: (hostId: string) => T | null,
  selfDevice: T | null,
): T | null {
  if (selectedHostId) return lookup(selectedHostId)
  return selfDevice
}

/** Summary/submit must refuse a hostId that no longer maps to a live Device. */
export function selectedHostIsLive(
  selectedHostId: string,
  lookup: (hostId: string) => unknown,
): boolean {
  if (!selectedHostId) return true
  return lookup(selectedHostId) != null
}

/** Alias: same reachability rule for templates, tasks, capabilities. */
export function canCallDeviceAPI(device: DeviceApiTarget): boolean {
  return canFetchDeviceWorkloads(device)
}

/** Member prefix only. Self callers must use the local path instead. */
export function deviceMemberPrefix(device: DeviceApiTarget): string {
  return `/home/devices/${encodeURIComponent(device.hostId)}/v1`
}

/** Map a local `/vms`-style path onto the picked Device. Self is unchanged. */
export function devicePath(device: DeviceApiTarget, localPath: string): string {
  const path = localPath.startsWith('/') ? localPath : `/${localPath}`
  if (isSelfDevice(device)) return path
  return `${deviceMemberPrefix(device)}${path}`
}

export function deviceVmsBasePath(device: DeviceApiTarget): string {
  return devicePath(device, '/vms')
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

export function deviceTemplatesPath(device: DeviceApiTarget): string {
  return devicePath(device, '/templates')
}

export function deviceTemplateDeployPath(device: DeviceApiTarget): string {
  return devicePath(device, '/templates/deploy')
}

export function deviceTemplateDryRunPath(device: DeviceApiTarget, templateId: string): string {
  return devicePath(device, `/templates/${encodeURIComponent(templateId)}/deploy/dry-run`)
}

export function deviceTaskPath(device: DeviceApiTarget, taskID: string): string {
  return devicePath(device, `/tasks/${encodeURIComponent(taskID)}`)
}

export function deviceCapabilitiesPath(device: DeviceApiTarget): string {
  return devicePath(device, '/system/capabilities')
}

export function deviceImagePath(device: DeviceApiTarget, imageId: string): string {
  return devicePath(device, `/images/${encodeURIComponent(imageId)}`)
}
