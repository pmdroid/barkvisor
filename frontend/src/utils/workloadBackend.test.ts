import { describe, expect, test } from 'bun:test'
import { acceleratorLabel, listBackendBadge, vmBackend } from './workloadBackend'
import type { VM, VMRuntimeBackend } from '../api/types'

function backend(partial: Partial<VMRuntimeBackend>): VMRuntimeBackend {
  return {
    accelerator: 'hvf',
    guestArch: 'arm64',
    qemuBinary: 'qemu-system-aarch64',
    emulated: false,
    warning: null,
    ...partial,
  }
}

describe('acceleratorLabel', () => {
  test('uppercases known backends', () => {
    expect(acceleratorLabel('hvf')).toBe('HVF')
    expect(acceleratorLabel('kvm')).toBe('KVM')
    expect(acceleratorLabel('tcg')).toBe('TCG')
    expect(acceleratorLabel('')).toBe('unknown')
  })
})

describe('listBackendBadge', () => {
  test('hidden for native hardware acceleration', () => {
    expect(listBackendBadge(backend({ emulated: false, accelerator: 'hvf' }))).toBeNull()
    expect(listBackendBadge(backend({ emulated: false, accelerator: 'kvm' }))).toBeNull()
    expect(listBackendBadge(null)).toBeNull()
  })

  test('TCG badge when software emulation is the effective accel', () => {
    const badge = listBackendBadge(
      backend({
        emulated: true,
        accelerator: 'tcg',
        warning: 'This workload is using TCG software emulation instead of hardware acceleration. Guests will be significantly slower.',
      }),
    )
    expect(badge?.label).toBe('TCG')
    expect(badge?.title).toContain('TCG')
  })

  test('Emulated badge for cross-arch without TCG accel name', () => {
    const badge = listBackendBadge(
      backend({
        emulated: true,
        accelerator: 'hvf',
        guestArch: 'x86_64',
        warning: 'guest architecture does not match',
      }),
    )
    expect(badge?.label).toBe('Emulated')
    expect(badge?.title).toContain('guest architecture')
  })
})

describe('vmBackend', () => {
  test('reads status.backend', () => {
    const b = backend({ accelerator: 'kvm' })
    expect(vmBackend({ status: { backend: b } as VM['status'] })).toEqual(b)
    expect(vmBackend({ status: undefined })).toBeNull()
  })
})
