import type { HostGPUDevice, OllamaCatalogModel, OllamaDeviceStatus } from '../api/types'
import { shouldFetchDeviceStatsHistory } from './deviceStatsHistory'
import { gpuGroupMatesLabel, gpuHostOccupancyLabel } from './gpuPassthrough'
import type { DeviceApiTarget } from './homeDeviceApi'
import { DEVICE_LABEL } from './terminology'

export { mapStatsHistorySamples, shouldFetchDeviceStatsHistory } from './deviceStatsHistory'

/** Occupancy list copy when `/system/gpu-devices` is empty. Never a blank chart. */
export const OLLAMA_GPU_EMPTY_COPY = `This ${DEVICE_LABEL} has no GPU.`

export function ollamaStatsUnreachableCopy(): string {
  return `This ${DEVICE_LABEL.toLowerCase()} did not answer. CPU, memory, and GPU are unknown.`
}

type RunningLocation = { hostId: string; running: boolean; reachable?: boolean }

/** Prefer the Device that already has a running model, then any reachable catalog Device. */
export function defaultOllamaStatsHostId(
  models: readonly Pick<OllamaCatalogModel, 'locations'>[],
  devices: readonly Pick<OllamaDeviceStatus, 'hostId' | 'reachable'>[],
): string {
  const locations = models.flatMap((row) => row.locations as RunningLocation[])
  const runningReachable = locations.find((loc) => loc.running && loc.reachable !== false)
  if (runningReachable) return runningReachable.hostId
  const running = locations.find((loc) => loc.running)
  if (running) return running.hostId
  return devices.find((row) => row.reachable)?.hostId ?? devices[0]?.hostId ?? ''
}

/** Catalog reachability wins. Health still gates member proxy like Device detail. */
export function shouldFetchOllamaDeviceStats(
  catalogDevice: Pick<OllamaDeviceStatus, 'reachable'> | null | undefined,
  health: DeviceApiTarget | null | undefined,
): boolean {
  if (!catalogDevice?.reachable) return false
  if (!health) return true
  return shouldFetchDeviceStatsHistory(health)
}

export function ollamaStatsApiTarget(
  hostId: string,
  catalogDevices: readonly Pick<OllamaDeviceStatus, 'hostId' | 'reachable'>[],
  healthByHostId: (id: string) => DeviceApiTarget | null,
  selfHostId?: string | null,
): DeviceApiTarget | null {
  if (!hostId) return null
  const health = healthByHostId(hostId)
  if (health) return health
  const catalog = catalogDevices.find((row) => row.hostId === hostId)
  if (!catalog) return null
  return {
    hostId,
    role: selfHostId === hostId ? 'self' : 'member',
    reachability: catalog.reachable ? 'ok' : 'unreachable',
  }
}

/** Host GPU occupancy from gpu-devices. sizeVRAM is model occupancy, not util%. */
export function ollamaGpuOccupancyLines(gpu: HostGPUDevice): string[] {
  const lines = [gpu.name]
  if (gpu.driver) lines.push(gpu.driver)
  if (gpu.vfioBound) lines.push('vfio-pci')
  if (gpu.claimedByVMName) {
    lines.push(`Attached to ${gpu.claimedByVMName}`)
  } else {
    const host = gpuHostOccupancyLabel(gpu.inUseByHost)
    if (host) lines.push(host)
  }
  if (gpu.attachable === false && gpu.excludedReason) lines.push(gpu.excludedReason)
  lines.push(`Group mates: ${gpuGroupMatesLabel(gpu.pciAddress, gpu.groupAddresses)}`)
  return lines
}

export function ollamaGpuEmptyCopy(gpus: readonly HostGPUDevice[] | null): string | null {
  if (gpus == null) return null
  return gpus.length === 0 ? OLLAMA_GPU_EMPTY_COPY : null
}
