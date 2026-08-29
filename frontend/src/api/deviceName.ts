import api from './client'
import { setupApi } from './setup'
import { devicePath, type DeviceApiTarget } from '../utils/homeDeviceApi'

export interface DeviceName {
  displayName: string
  hostname: string
}

/** Local `/system/device-name`. Members hop through Home. */
export function deviceNamePath(device: DeviceApiTarget): string {
  return devicePath(device, '/system/device-name')
}

export async function getDeviceName(device: DeviceApiTarget): Promise<DeviceName> {
  const { data } = await api.get<DeviceName>(deviceNamePath(device))
  return data
}

export async function saveDeviceName(
  displayName: string,
  device: DeviceApiTarget,
): Promise<DeviceName> {
  const { data } = await api.put<DeviceName>(deviceNamePath(device), { displayName })
  return data
}

export async function getSetupDeviceName(): Promise<DeviceName> {
  const { data } = await setupApi.get<DeviceName>('/device-name')
  return data
}

export async function saveSetupDeviceName(displayName: string): Promise<DeviceName> {
  const { data } = await setupApi.put<DeviceName>('/device-name', { displayName })
  return data
}
