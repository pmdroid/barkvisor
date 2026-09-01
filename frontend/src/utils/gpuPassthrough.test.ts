import { describe, expect, test } from 'bun:test'
import { defaultCapabilities } from './capabilitiesParse'
import {
  GUEST_OLLAMA_PATH,
  GPU_IOMMU_NOT_READY,
  GPU_PASSTHROUGH_DOCS_HREF,
  GPU_SINGLE_DISPLAY_WARNING,
  gpuDetachAllowed,
  gpuGroupMateAddresses,
  gpuGroupMatesLabel,
  gpuHostOccupancyLabel,
  gpuPassthroughExplanation,
  gpuPassthroughSupported,
  gpuVendorGroupKey,
  gpuVendorLabel,
  groupGpusByVendor,
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

  test('IOMMU setup docs href is the published guide', () => {
    expect(GPU_PASSTHROUGH_DOCS_HREF).toBe('https://barkvisor.dev/docs/guides/gpu-passthrough/')
  })
})

describe('gpu vendor labels', () => {
  test('maps PCI vendor ids to NVIDIA Intel AMD Other', () => {
    expect(gpuVendorLabel('10de')).toBe('NVIDIA')
    expect(gpuVendorLabel('8086')).toBe('Intel')
    expect(gpuVendorLabel('1002')).toBe('AMD')
    expect(gpuVendorLabel('1234')).toBe('Other')
    expect(gpuVendorLabel('0x10de')).toBe('NVIDIA')
    expect(gpuVendorGroupKey('10de')).toBe('NVIDIA')
    expect(gpuVendorGroupKey('8086')).toBe('Intel')
    expect(gpuVendorGroupKey('1002')).toBe('AMD')
    expect(gpuVendorGroupKey('abcd')).toBe('Other')
  })

  test('keeps two NVIDIA cards distinct by PCI address', () => {
    const grouped = groupGpusByVendor([
      { pciAddress: '0000:01:00.0', vendorId: '10de' },
      { pciAddress: '0000:00:02.0', vendorId: '8086' },
      { pciAddress: '0000:81:00.0', vendorId: '10de' },
      { pciAddress: '0000:03:00.0', vendorId: '1002' },
      { pciAddress: '0000:04:00.0', vendorId: '1234' },
    ])
    expect(grouped.map((group) => group.label)).toEqual(['NVIDIA', 'Intel', 'AMD', 'Other'])
    const nvidia = grouped.find((group) => group.label === 'NVIDIA')
    expect(nvidia?.devices.map((gpu) => gpu.pciAddress)).toEqual([
      '0000:01:00.0',
      '0000:81:00.0',
    ])
    expect(nvidia?.devices).toHaveLength(2)
    expect(grouped.flatMap((group) => group.devices)).toHaveLength(5)
  })
})
