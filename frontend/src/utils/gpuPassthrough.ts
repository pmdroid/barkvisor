import type { CapabilityDetail, CurrentHostCapabilities } from '../api/types'

/** Guest-local Ollama when a GPU is attached. Host Ollama is not used for that card. */
export const GUEST_OLLAMA_PATH = 'http://127.0.0.1:11434/v1'

export const GPU_IOMMU_NOT_READY =
  'GPU passthrough needs IOMMU, vfio-pci, KVM, and a GPU in an IOMMU group. This Device is not ready.'

export const GPU_SINGLE_DISPLAY_WARNING =
  'This Device lists one GPU. Passing it through can blank the host display.'

/** Other PCI addresses in the same IOMMU group (not the GPU itself). */
export function gpuGroupMateAddresses(
  pciAddress: string,
  groupAddresses?: string[] | null,
): string[] {
  return (groupAddresses ?? []).filter((addr) => addr && addr !== pciAddress)
}

export function gpuGroupMatesLabel(
  pciAddress: string,
  groupAddresses?: string[] | null,
): string {
  const mates = gpuGroupMateAddresses(pciAddress, groupAddresses)
  return mates.length ? mates.join(', ') : 'none'
}

export function gpuPassthroughDetail(
  caps: CurrentHostCapabilities | null | undefined,
): CapabilityDetail | undefined {
  return caps?.details?.find((row) => row.code === 'gpuPassthrough')
}

/** Server remediation when unsupported; otherwise explain attach and guest Ollama. */
export function gpuPassthroughExplanation(
  caps: CurrentHostCapabilities | null | undefined,
): string {
  const row = gpuPassthroughDetail(caps)
  if (row?.supported) {
    return `This Device has IOMMU, vfio-pci, and KVM. Attach a GPU like USB. Guest Ollama is ${GUEST_OLLAMA_PATH}. The same card cannot be host and guest.`
  }
  if (row?.remediation) return row.remediation
  const platform = caps?.platform ?? ''
  if (platform.toLowerCase() === 'macos') {
    return 'GPU passthrough is not available on macOS. Use a Linux Device with IOMMU, vfio-pci, and KVM.'
  }
  return GPU_IOMMU_NOT_READY
}

export function gpuPassthroughSupported(
  caps: CurrentHostCapabilities | null | undefined,
): boolean {
  if (!caps) return false
  if (caps.supportsGPUPassthrough === true) return true
  return gpuPassthroughDetail(caps)?.supported === true
}

/** Occupancy is the host GPU driver, not an Ollama TCP probe. */
export function gpuHostOccupancyLabel(inUseByHost: boolean | undefined): string | null {
  return inUseByHost ? 'In use by host' : null
}

/** vfio-pci is bound at start. Detach is only safe when the Workload is stopped. */
export function gpuDetachAllowed(state: string | undefined): boolean {
  return state === 'stopped' || state === 'error'
}
