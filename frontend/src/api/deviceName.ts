import api from './client'
import { setupApi } from './setup'

export interface DeviceName {
  displayName: string
  hostname: string
}

export async function getDeviceName(): Promise<DeviceName> {
  const { data } = await api.get<DeviceName>('/system/device-name')
  return data
}

export async function saveDeviceName(displayName: string): Promise<DeviceName> {
  const { data } = await api.put<DeviceName>('/system/device-name', { displayName })
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
