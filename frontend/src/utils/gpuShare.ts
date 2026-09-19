import type { HostGPUShareDevice } from '../api/types'

export function gpuShareVisible(devices: HostGPUShareDevice[]): boolean {
  return devices.length > 0
}

export function defaultGPUShareIds(devices: HostGPUShareDevice[]): string[] {
  return devices.filter((device) => device.attachable).map((device) => device.id)
}

export function gpuFactNames(
  devices: readonly { name?: string | null }[],
  share: readonly { name?: string | null }[] = [],
): string {
  const names: string[] = []
  const seen = new Set<string>()
  for (const row of [...devices, ...share]) {
    const name = row.name?.trim()
    if (!name || seen.has(name)) continue
    seen.add(name)
    names.push(name)
  }
  return names.join(', ')
}

export function gpuShareOccupancy(device: HostGPUShareDevice): string {
  if (device.claimedByVMName) return `Attached to ${device.claimedByVMName}`
  return device.excludedReason || ''
}
