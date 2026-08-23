import type { CapabilityDetail, CurrentHostCapabilities } from '../api/types'

/** BarkVisor probes IOMMU/vfio. It does not attach a GPU to a Workload. */
export const GPU_ATTACH_UNAVAILABLE =
  'BarkVisor does not attach a GPU to a Workload yet.'

export function gpuPassthroughDetail(
  caps: CurrentHostCapabilities | null | undefined,
): CapabilityDetail | undefined {
  return caps?.details?.find((row) => row.code === 'gpuPassthrough')
}

/** Server remediation when unsupported; otherwise explain that attach is not offered. */
export function gpuPassthroughExplanation(
  caps: CurrentHostCapabilities | null | undefined,
): string {
  const row = gpuPassthroughDetail(caps)
  if (row?.supported) {
    return `This Device has IOMMU, vfio-pci, and KVM. ${GPU_ATTACH_UNAVAILABLE}`
  }
  if (row?.remediation) return row.remediation
  const platform = caps?.platform ?? ''
  if (platform.toLowerCase() === 'macos') {
    return 'GPU passthrough is not available on macOS. Use a Linux Device with IOMMU, vfio-pci, and KVM.'
  }
  return `GPU passthrough is not available on this Device. ${GPU_ATTACH_UNAVAILABLE}`
}

export function gpuPassthroughSupported(
  caps: CurrentHostCapabilities | null | undefined,
): boolean {
  if (!caps) return false
  if (caps.supportsGPUPassthrough === true) return true
  return gpuPassthroughDetail(caps)?.supported === true
}
