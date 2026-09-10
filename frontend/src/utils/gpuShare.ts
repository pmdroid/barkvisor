import type { HostGPUShareDevice } from '../api/types'

export function gpuShareVisible(devices: HostGPUShareDevice[]): boolean {
  return devices.length > 0
}

export function defaultGPUShareIds(devices: HostGPUShareDevice[]): string[] {
  return devices.filter((device) => device.attachable).map((device) => device.id)
}

export function gpuShareOccupancy(device: HostGPUShareDevice): string {
  if (device.claimedByVMName) return `Attached to ${device.claimedByVMName}`
  return device.excludedReason || ''
}
