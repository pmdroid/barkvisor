import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { nextTick } from 'vue'
import api from '../api/client'
import type { HomeDeviceHealthReport, HomeDeviceHealthSnapshot, SSHKey } from '../api/types'
import { useDevicesStore } from '../stores/devices'
import { useCreateVMWizard } from './useCreateVMWizard'

const originalGet = api.get

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

function sshKey(id: string): SSHKey {
  return {
    id,
    name: id,
    publicKey: `ssh-ed25519 ${id}`,
    fingerprint: id,
    keyType: 'ssh-ed25519',
    isDefault: true,
    createdAt: '2026-01-01T00:00:00Z',
  }
}

async function waitForCurrentInventory(
  wizard: ReturnType<typeof useCreateVMWizard>,
  hostId: string,
) {
  for (let i = 0; i < 50; i++) {
    if (
      !wizard.pickedDeviceLoading.value
      && wizard.selectedHostId.value === hostId
      && wizard.hostArch.value === (hostId === 'alpha' ? 'x86_64' : 'arm64')
      && wizard.sshKeys.value[0]?.id === `key-${hostId}`
    ) {
      return
    }
    await nextTick()
  }
  throw new Error(
    `inventory for ${hostId} did not settle (loading=${wizard.pickedDeviceLoading.value} arch=${wizard.hostArch.value} keys=${wizard.sshKeys.value.map((k) => k.id).join(',')})`,
  )
}

function inventoryGet(hostId: string, url: string) {
  const prefix = `/home/devices/${hostId}/v1`
  if (url === `${prefix}/system/capabilities`) {
    return { data: { hostArch: hostId === 'alpha' ? 'x86_64' : 'arm64' } }
  }
  if (url === `${prefix}/ssh-keys`) {
    return { data: [sshKey(`key-${hostId}`)] }
  }
  if (url === `${prefix}/images` || url === `${prefix}/networks` || url === `${prefix}/disks`) {
    return { data: [{ id: `${hostId}-res` }] }
  }
  throw new Error(`unexpected GET ${url}`)
}

describe('useCreateVMWizard (PAS-34)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
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

  test('a slower inventory fetch for an earlier Device does not overwrite the current pick', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'alpha', role: 'member', displayName: 'alpha' }),
      device({ hostId: 'beta', role: 'member', displayName: 'beta' }),
    ])
    devices.report = health

    let releaseSlow: (() => void) | undefined
    const slowGate = new Promise<void>((resolve) => {
      releaseSlow = resolve
    })
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url.startsWith('/home/devices/alpha/')) {
        return slowGate.then(() => inventoryGet('alpha', url))
      }
      if (url.startsWith('/home/devices/beta/')) {
        return Promise.resolve(inventoryGet('beta', url))
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get

    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'alpha' })
    const stale = wizard.loadPickedDevice()
    wizard.selectedHostId.value = 'beta'
    await nextTick()
    await wizard.loadPickedDevice()
    await waitForCurrentInventory(wizard, 'beta')
    releaseSlow?.()
    await stale

    expect(wizard.selectedHostId.value).toBe('beta')
    expect(wizard.hostArch.value).toBe('arm64')
    expect(wizard.sshKeys.value.map((key) => key.id)).toEqual(['key-beta'])
    expect(wizard.error.value).toBe('')
  })

  test('a failed stale inventory fetch does not clear the current Device inventory', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'alpha', role: 'member', displayName: 'alpha' }),
      device({ hostId: 'beta', role: 'member', displayName: 'beta' }),
    ])
    devices.report = health

    let rejectSlow: ((err: Error) => void) | undefined
    const slowFail = new Promise<never>((_resolve, reject) => {
      rejectSlow = reject
    })
    void slowFail.catch(() => {})
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url.startsWith('/home/devices/alpha/')) return slowFail
      if (url.startsWith('/home/devices/beta/')) return Promise.resolve(inventoryGet('beta', url))
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get

    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'alpha' })
    const stale = wizard.loadPickedDevice()
    wizard.selectedHostId.value = 'beta'
    await nextTick()
    await wizard.loadPickedDevice()
    await waitForCurrentInventory(wizard, 'beta')
    rejectSlow?.(new Error('alpha timed out'))
    await stale

    expect(wizard.hostArch.value).toBe('arm64')
    expect(wizard.sshKeys.value.map((key) => key.id)).toEqual(['key-beta'])
    expect(wizard.error.value).toBe('')
  })
})
