import { describe, expect, test } from 'bun:test'
import type { HostGPUShareDevice } from '../api/types'
import { defaultGPUShareIds, gpuShareOccupancy, gpuShareVisible } from './gpuShare'

function card(partial: Partial<HostGPUShareDevice> & Pick<HostGPUShareDevice, 'id' | 'label'>): HostGPUShareDevice {
  return {
    kind: 'drm',
    name: partial.label,
    attachable: true,
    ...partial,
  }
}

describe('gpuShare', () => {
  test('macos empty inventory hides the section', () => {
    expect(gpuShareVisible([])).toBe(false)
    expect(defaultGPUShareIds([])).toEqual([])
  })

  test('defaults attachable cards on and skips vfio', () => {
    const devices = [
      card({ id: '0000:00:02.0', label: 'Intel UHD (renderD128)' }),
      card({ id: 'GPU-aaaa', kind: 'nvidia', label: 'NVIDIA (GPU-aaaa)' }),
      card({
        id: '0000:02:00.0',
        label: 'NVIDIA (vfio-pci)',
        attachable: false,
        vfioBound: true,
        claimedByVMName: 'coder',
      }),
    ]
    expect(gpuShareVisible(devices)).toBe(true)
    expect(defaultGPUShareIds(devices)).toEqual(['0000:00:02.0', 'GPU-aaaa'])
    expect(gpuShareOccupancy(devices[2])).toBe('Attached to coder')
  })
})
