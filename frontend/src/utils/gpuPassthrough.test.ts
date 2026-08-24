import { describe, expect, test } from 'bun:test'
import { defaultCapabilities } from './capabilitiesParse'
import {
  GUEST_OLLAMA_PATH,
  GPU_IOMMU_NOT_READY,
  GPU_SINGLE_DISPLAY_WARNING,
  gpuDetachAllowed,
  gpuGroupMateAddresses,
  gpuGroupMatesLabel,
  gpuHostOccupancyLabel,
  gpuPassthroughExplanation,
  gpuPassthroughSupported,
} from './gpuPassthrough'

describe('gpuPassthrough copy (PAS-275)', () => {
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

  test('ready host explains attach and guest Ollama', () => {
    const caps = {
      ...defaultCapabilities,
      platform: 'Linux',
      supportsGPUPassthrough: true,
      supportsVFIO: true,
      details: [{ code: 'gpuPassthrough', supported: true }],
    }
    expect(gpuPassthroughSupported(caps)).toBe(true)
    expect(gpuPassthroughExplanation(caps)).toContain(GUEST_OLLAMA_PATH)
    expect(gpuPassthroughExplanation(caps)).toContain('same card cannot be host and guest')
    expect(gpuPassthroughExplanation(caps)).not.toContain('not attach')
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

  test('host occupancy is the driver not Ollama', () => {
    expect(gpuHostOccupancyLabel(true)).toBe('In use by host')
    expect(gpuHostOccupancyLabel(false)).toBeNull()
    expect(gpuHostOccupancyLabel(undefined)).toBeNull()
  })

  test('detach is only allowed when the Workload is stopped', () => {
    expect(gpuDetachAllowed('stopped')).toBe(true)
    expect(gpuDetachAllowed('error')).toBe(true)
    expect(gpuDetachAllowed('running')).toBe(false)
    expect(gpuDetachAllowed('starting')).toBe(false)
    expect(gpuDetachAllowed('stopping')).toBe(false)
    expect(gpuDetachAllowed(undefined)).toBe(false)
  })

  test('group mates omit the GPU itself', () => {
    expect(gpuGroupMateAddresses('0000:01:00.0', ['0000:01:00.0', '0000:01:00.1'])).toEqual([
      '0000:01:00.1',
    ])
    expect(gpuGroupMatesLabel('0000:01:00.0', ['0000:01:00.0', '0000:01:00.1'])).toBe('0000:01:00.1')
    expect(gpuGroupMatesLabel('0000:01:00.0', ['0000:01:00.0'])).toBe('none')
    expect(gpuGroupMatesLabel('0000:01:00.0', undefined)).toBe('none')
  })

  test('single-GPU display warning is loud copy', () => {
    expect(GPU_SINGLE_DISPLAY_WARNING).toContain('one GPU')
    expect(GPU_SINGLE_DISPLAY_WARNING).toContain('host display')
  })
})
