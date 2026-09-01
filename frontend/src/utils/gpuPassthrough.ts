import type { CapabilityDetail, CurrentHostCapabilities } from '../api/types'

/** PCI vendor labels for display-class GPUs. Unknown ids are Other, not GPU. */
export type GpuVendorLabel = 'NVIDIA' | 'Intel' | 'AMD' | 'Other'

export type GpuVendorGroup<T extends { vendorId: string } = { vendorId: string }> = {
  key: GpuVendorLabel
  label: GpuVendorLabel
  devices: T[]
}

const GPU_VENDOR_GROUP_ORDER: readonly GpuVendorLabel[] = ['NVIDIA', 'Intel', 'AMD', 'Other']

/** Match GPUPassthroughService.normalizeHexId. */
function normalizeVendorId(raw: string): string {
  let value = raw.trim().toLowerCase()
  if (value.startsWith('0x')) value = value.slice(2)
  return value
}

export function gpuVendorLabel(vendorId: string): GpuVendorLabel {
  switch (normalizeVendorId(vendorId)) {
    case '10de':
      return 'NVIDIA'
    case '8086':
      return 'Intel'
    case '1002':
      return 'AMD'
    default:
      return 'Other'
  }
}

export function gpuVendorGroupKey(vendorId: string): GpuVendorLabel {
  return gpuVendorLabel(vendorId)
}

/** Group display GPUs by vendor. Same-vendor cards stay distinct; no vendor dedupe. */
export function groupGpusByVendor<T extends { vendorId: string }>(
  gpus: readonly T[],
): GpuVendorGroup<T>[] {
  const buckets = new Map<GpuVendorLabel, T[]>()
  for (const gpu of gpus) {
    const key = gpuVendorGroupKey(gpu.vendorId)
    const list = buckets.get(key)
    if (list) list.push(gpu)
    else buckets.set(key, [gpu])
  }
  return GPU_VENDOR_GROUP_ORDER.flatMap((key) => {
    const devices = buckets.get(key)
    return devices?.length ? [{ key, label: key, devices }] : []
  })
}

export const GPU_IOMMU_NOT_READY =
  'GPU passthrough needs IOMMU, vfio-pci, KVM, and a GPU in an IOMMU group. This machine is not ready.'

export const GPU_SINGLE_DISPLAY_WARNING =
  'This machine lists one GPU. Passing it through can blank the host display.'

export const GPU_PASSTHROUGH_DOCS_HREF = 'https://barkvisor.dev/docs/guides/gpu-passthrough/'

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
    return 'This machine has IOMMU, vfio-pci, and KVM. Attach a GPU like USB. The same card cannot be host and guest.'
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
