import { beforeEach, describe, expect, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import type { HomeDeviceHealthReport, HomeDeviceHealthSnapshot } from '../api/types'
import { useDevicesStore } from '../stores/devices'
import { useCreateVMWizard } from './useCreateVMWizard'

function device(
  partial: Partial<HomeDeviceHealthSnapshot> & Pick<HomeDeviceHealthSnapshot, 'hostId' | 'role'>,
): HomeDeviceHealthSnapshot {
  return {
    agentPort: 7778,
    reachability: 'ok',
    platform: { os: 'macOS', arch: 'arm64' },
    ...partial,
  }
}

function report(devices: HomeDeviceHealthSnapshot[]): HomeDeviceHealthReport {
  return {
    devices,
    totals: {
      devices: devices.length,
      reachable: devices.length,
      unreachable: 0,
      workloadCount: 0,
      healthCounts: {},
    },
  }
}

describe('useCreateVMWizard (PAS-34)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  test('picker uses the configured guest arch for every Device, not each row host arch', () => {
    const devices = useDevicesStore()
    devices.report = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
      device({
        hostId: 'box',
        role: 'member',
        displayName: 'box',
        platform: { os: 'Linux', arch: 'x86_64' },
      }),
    ])

    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'desk' })
    expect(wizard.effectiveGuestArch.value).toBe('arm64')

    const peer = wizard.deviceOptions.value.find((row) => row.hostId === 'box')
    expect(peer?.compatible).toBe(false)
    expect(peer?.reasons.some((reason) => reason.includes('arm64'))).toBe(true)

    const self = wizard.deviceOptions.value.find((row) => row.hostId === 'desk')
    expect(self?.compatible).toBe(true)
  })

  test('Next and submit stay blocked while the picked Device inventory is loading', async () => {
    const wizard = useCreateVMWizard(() => {})
    wizard.name.value = 'vm'
    expect(wizard.canProceed()).toBe(false)
    await wizard.submit()
    expect(wizard.loading.value).toBe(false)
    expect(wizard.error.value).toBe('')
  })
})
