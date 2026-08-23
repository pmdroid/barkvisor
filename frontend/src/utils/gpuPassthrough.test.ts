import { describe, expect, test } from 'bun:test'
import { defaultCapabilities } from './capabilitiesParse'
import {
  GPU_ATTACH_UNAVAILABLE,
  gpuPassthroughExplanation,
  gpuPassthroughSupported,
} from './gpuPassthrough'

describe('gpuPassthrough copy (PAS-274)', () => {
  test('macos uses os remediation and is unsupported', () => {
    const caps = {
      ...defaultCapabilities,
      platform: 'macOS',
      supportsGPUPassthrough: false,
      details: [
        {
          code: 'gpuPassthrough',
          supported: false,
          reasonCode: 'os_unsupported',
          remediation: 'GPU passthrough is not available on macOS. Use a Linux Device with IOMMU, vfio-pci, and KVM.',
        },
      ],
    }
    expect(gpuPassthroughSupported(caps)).toBe(false)
    expect(gpuPassthroughExplanation(caps)).toContain('macOS')
    expect(gpuPassthroughExplanation(caps)).not.toMatch(/node|cluster/i)
  })

  test('ready host still explains that attach is not offered', () => {
    const caps = {
      ...defaultCapabilities,
      platform: 'Linux',
      supportsGPUPassthrough: true,
      supportsVFIO: true,
      details: [{ code: 'gpuPassthrough', supported: true }],
    }
    expect(gpuPassthroughSupported(caps)).toBe(true)
    expect(gpuPassthroughExplanation(caps)).toContain(GPU_ATTACH_UNAVAILABLE)
  })

  test('linux missing kvm uses actionable server remediation', () => {
    const caps = {
      ...defaultCapabilities,
      platform: 'Linux',
      details: [
        {
          code: 'gpuPassthrough',
          supported: false,
          reasonCode: 'kvm_missing',
          remediation:
            'GPU passthrough needs KVM (/dev/kvm). Install qemu-kvm, add this user to the kvm group, or enable nested virtualization, then confirm /dev/kvm exists.',
        },
      ],
    }
    expect(gpuPassthroughSupported(caps)).toBe(false)
    expect(gpuPassthroughExplanation(caps)).toContain('qemu-kvm')
    expect(gpuPassthroughExplanation(caps)).toMatch(/nested/i)
    expect(gpuPassthroughExplanation(caps)).not.toMatch(/node|cluster|quorum/i)
  })

  test('linux missing iommu uses server remediation', () => {
    const caps = {
      ...defaultCapabilities,
      platform: 'Linux',
      details: [
        {
          code: 'gpuPassthrough',
          supported: false,
          reasonCode: 'iommu_missing',
          remediation: 'IOMMU is not active (0 IOMMU groups). Enable intel_iommu=on or amd_iommu=on on the kernel command line, then reboot.',
        },
      ],
    }
    expect(gpuPassthroughSupported(caps)).toBe(false)
    expect(gpuPassthroughExplanation(caps)).toContain('intel_iommu')
  })
})
