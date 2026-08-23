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

/** Manual pick only. Default to the explicit initial host or self — never auto-place. */
export function defaultPickedHostId(
  initialHostId?: string | null,
  selfHostId?: string | null,
): string {
  return initialHostId || selfHostId || ''
}

/** Alias: same reachability rule for templates, tasks, capabilities. */
export function canCallDeviceAPI(device: DeviceApiTarget): boolean {
  return canFetchDeviceWorkloads(device)
}

/** Local images/networks/disks belong to this process only. SSH keys live on Home. */
export function usesLocalDeviceInventory(device: DeviceApiTarget): boolean {
  return isSelfDevice(device)
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

export function deviceVmSessionPath(
  device: DeviceApiTarget,
  vmId: string,
  action: 'resume' | 'reset' | 'burn',
): string {
  return `${deviceVmPath(device, vmId)}/session/${action}`
}

export function deviceVmSpecPath(device: DeviceApiTarget, vmId: string): string {
  return `${deviceVmPath(device, vmId)}/spec`
}

export function deviceGuestInfoPath(device: DeviceApiTarget, vmId: string): string {
  return `${deviceVmPath(device, vmId)}/guest-info`
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

export function deviceHostBridgeReadinessPath(device: DeviceApiTarget): string {
  return devicePath(device, '/system/host-bridge-readiness')
}

export function deviceImagePath(device: DeviceApiTarget, imageId: string): string {
  return devicePath(device, `/images/${encodeURIComponent(imageId)}`)
}

export function deviceLogsPath(device: DeviceApiTarget): string {
  return devicePath(device, '/logs')
}

export function deviceVmMetricsPath(device: DeviceApiTarget, vmId: string): string {
  return `${deviceVmPath(device, vmId)}/metrics`
}

export function deviceUsbDevicesPath(device: DeviceApiTarget): string {
  return devicePath(device, '/system/usb-devices')
}

export function deviceVmUsbPath(device: DeviceApiTarget, vmId: string): string {
  return `${deviceVmPath(device, vmId)}/usb`
}

export function deviceVmUsbDevicePath(
  device: DeviceApiTarget,
  vmId: string,
  usbId: string,
): string {
  return `${deviceVmUsbPath(device, vmId)}/${encodeURIComponent(usbId)}`
}

export function deviceGpuDevicesPath(device: DeviceApiTarget): string {
  return devicePath(device, '/system/gpu-devices')
}

export function deviceVmGpuPath(device: DeviceApiTarget, vmId: string): string {
  return `${deviceVmPath(device, vmId)}/gpu`
}

export function deviceVmGpuDevicePath(
  device: DeviceApiTarget,
  vmId: string,
  gpuId: string,
): string {
  return `${deviceVmGpuPath(device, vmId)}/${encodeURIComponent(gpuId)}`
}

export function deviceDisksPath(device: DeviceApiTarget): string {
  return devicePath(device, '/disks')
}

export function deviceDiskPath(device: DeviceApiTarget, diskId: string): string {
  return `${deviceDisksPath(device)}/${encodeURIComponent(diskId)}`
}

export function deviceDiskUsagePath(device: DeviceApiTarget, diskId: string): string {
  return `${deviceDiskPath(device, diskId)}/usage`
}

export function deviceDiskResizePath(device: DeviceApiTarget, diskId: string): string {
  return `${deviceDiskPath(device, diskId)}/resize`
}

export function deviceDiskSummaryPath(device: DeviceApiTarget): string {
  return `${deviceDisksPath(device)}/summary`
}

export function deviceNetworksPath(device: DeviceApiTarget): string {
  return devicePath(device, '/networks')
}

export function deviceNetworkPath(device: DeviceApiTarget, networkId: string): string {
  return `${deviceNetworksPath(device)}/${encodeURIComponent(networkId)}`
}

export function deviceInterfacesPath(device: DeviceApiTarget): string {
  return devicePath(device, '/system/interfaces')
}

export function deviceBridgesPath(device: DeviceApiTarget): string {
  return devicePath(device, '/system/bridges')
}

/** Mint the WS ticket on the owning Device (This Device or member via Home). */
export function deviceWsTicketPath(device: DeviceApiTarget): string {
  return devicePath(device, '/auth/ws-ticket')
}

export function deviceVmVncPath(device: DeviceApiTarget, vmId: string): string {
  return `${deviceVmPath(device, vmId)}/vnc`
}

export function deviceVmConsolePath(device: DeviceApiTarget, vmId: string): string {
  return `${deviceVmPath(device, vmId)}/console`
}
