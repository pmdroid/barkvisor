/** Home Workload remaining HTTP control (PAS-203).
 *  Spec, USB, disks, networks, metrics snapshots, and log history go
 *  through devicePath. Members poll — the Home proxy does not forward Upgrade. */

import type { UpdateVMRequest } from '../api/types'
import {
  canFetchDeviceWorkloads,
  deviceDisksPath,
  deviceLogsPath,
  deviceNetworksPath,
  deviceUsbDevicesPath,
  deviceVmMetricsPath,
  isSelfDevice,
  type DeviceApiTarget,
} from './homeDeviceApi'

export {
  deviceDiskUsagePath,
  deviceDisksPath,
  deviceLogsPath,
  deviceNetworksPath,
  deviceUsbDevicesPath,
  deviceVmMetricsPath,
  deviceVmUsbDevicePath,
  deviceVmUsbPath,
} from './homeDeviceApi'

export function canEditMemberHardware(device: DeviceApiTarget | null | undefined): boolean {
  return Boolean(device && canFetchDeviceWorkloads(device))
}

/** Self may use EventSource. Members must poll JSON through the HTTP proxy. */
export function shouldPollDeviceControl(device: DeviceApiTarget | null | undefined): boolean {
  if (!device) return false
  return !isSelfDevice(device)
}

export function logsHistoryFetchPath(
  device: DeviceApiTarget | null | undefined,
): string | null {
  if (!device || !canEditMemberHardware(device)) return null
  return deviceLogsPath(device)
}

export function metricsHistoryFetchPath(
  device: DeviceApiTarget | null | undefined,
  vmId: string,
  vmState: string | undefined,
): string | null {
  if (!device || !canEditMemberHardware(device)) return null
  if (vmState !== 'running') return null
  return deviceVmMetricsPath(device, vmId)
}

export function usbInventoryFetchPath(
  device: DeviceApiTarget | null | undefined,
): string | null {
  if (!device || !canEditMemberHardware(device)) return null
  return deviceUsbDevicesPath(device)
}

export function disksInventoryFetchPath(
  device: DeviceApiTarget | null | undefined,
): string | null {
  if (!device || !canEditMemberHardware(device)) return null
  return deviceDisksPath(device)
}

export function networksInventoryFetchPath(
  device: DeviceApiTarget | null | undefined,
): string | null {
  if (!device || !canEditMemberHardware(device)) return null
  return deviceNetworksPath(device)
}

/** Member detail may open overview, metrics, and logs. Never console/vnc. */
export function isMemberControlTab(tab: string): boolean {
  return tab === 'overview' || tab === 'metrics' || tab === 'logs'
}

export function memberControlTabAllowed(
  tab: string,
  vmState: string | undefined,
): boolean {
  if (tab === 'overview' || tab === 'logs') return true
  if (tab === 'metrics') return vmState === 'running'
  return false
}

/** Member inventory only — never Home's /networks list. */
export function memberNetworkForDetail<T extends { id: string; isDefault?: boolean }>(
  networkId: string | null | undefined,
  networks: T[],
): T | null {
  if (!networkId) return networks.find((n) => n.isDefault) ?? null
  return networks.find((n) => n.id === networkId) ?? null
}

/** Drop targetHostId. Route by URL (devicePath), never a body field. */
export function hardwarePatchBody(
  body: UpdateVMRequest & { targetHostId?: string },
): UpdateVMRequest {
  const { targetHostId: _ignored, ...patch } = body
  return patch
}
