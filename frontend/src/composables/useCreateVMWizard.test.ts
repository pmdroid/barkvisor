import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { nextTick } from 'vue'
import api from '../api/client'
import type { HomeDeviceHealthReport, HomeDeviceHealthSnapshot, SSHKey } from '../api/types'
import { useDevicesStore } from '../stores/devices'
import { useCreateVMWizard } from './useCreateVMWizard'

const originalGet = api.get
const originalPost = api.post

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
    api.post = mock((url: string) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({ data: { recommendedHostId: null, candidates: [] } })
      }
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
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

  test('This Device stays selectable when placement recommends a foreign-arch member', () => {
    const devices = useDevicesStore()
    devices.report = report([
      device({
        hostId: 'box',
        role: 'self',
        displayName: 'agentbox',
        platform: { os: 'Linux', arch: 'x86_64' },
      }),
      device({
        hostId: 'orb',
        role: 'member',
        displayName: 'barkvisor-u24',
        platform: { os: 'Linux', arch: 'arm64' },
      }),
    ])

    const wizard = useCreateVMWizard(() => {})
    expect(wizard.effectiveGuestArch.value).toBe('x86_64')

    const self = wizard.deviceOptions.value.find((row) => row.hostId === 'box')
    const peer = wizard.deviceOptions.value.find((row) => row.hostId === 'orb')
    expect(self?.compatible).toBe(true)
    expect(peer?.compatible).toBe(false)
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

  test('pre-selects the recommended Device and keeps an operator override', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
      device({ hostId: 'studio', role: 'member', displayName: 'studio' }),
    ])
    devices.report = health
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({ data: { hostArch: 'arm64' } })
      }
      if (
        url === '/images' || url === '/networks' || url === '/disks' || url === '/ssh-keys'
        || url.endsWith('/images') || url.endsWith('/networks') || url.endsWith('/disks') || url.endsWith('/ssh-keys')
      ) {
        return Promise.resolve({ data: [] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({
          data: {
            recommendedHostId: 'studio',
            candidates: [
              {
                hostId: 'studio',
                role: 'member',
                eligible: true,
                recommended: true,
                rank: 1,
                score: 90,
                reasons: [{ code: 'headroom', kind: 'soft', message: '6 GB free, 5% CPU.' }],
              },
              {
                hostId: 'desk',
                role: 'self',
                eligible: true,
                recommended: false,
                rank: 2,
                score: 40,
                reasons: [{ code: 'headroom', kind: 'soft', message: '1 GB free, 40% CPU.' }],
              },
            ],
          },
        })
      }
      throw new Error(`unexpected POST ${url}`)
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post
    const wizard = useCreateVMWizard(() => {})
    await wizard.loadPickedDevice()
    expect(wizard.selectedHostId.value).toBe('studio')
    expect(wizard.deviceOptions.value.find((row) => row.hostId === 'studio')?.recommended).toBe(true)
    wizard.selectedHostId.value = 'desk'
    await nextTick()
    await wizard.loadPickedDevice()
    expect(wizard.selectedHostId.value).toBe('desk')
  })

  test('re-scores placement when memory or guest arch changes and blocks submit without headroom', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
    ])
    devices.report = health
    const scoreBodies: Array<Record<string, unknown>> = []
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({ data: { hostArch: 'arm64' } })
      }
      if (
        url === '/images' || url === '/networks' || url === '/disks' || url === '/ssh-keys'
        || url.endsWith('/images') || url.endsWith('/networks') || url.endsWith('/disks') || url.endsWith('/ssh-keys')
      ) {
        return Promise.resolve({ data: [] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string, body?: Record<string, unknown>) => {
      if (url === '/home/placement/score') {
        const requested = typeof body?.requestedMemoryMB === 'number' ? body.requestedMemoryMB : 1024
        scoreBodies.push(body ?? {})
        const eligible = requested <= 1024
        return Promise.resolve({
          data: {
            recommendedHostId: eligible ? 'desk' : null,
            candidates: [
              {
                hostId: 'desk',
                role: 'self',
                eligible,
                recommended: eligible,
                rank: 1,
                score: eligible ? 80 : 0,
                reasons: eligible
                  ? [{ code: 'headroom', kind: 'soft', message: '2048 MB free memory, 10% CPU load.' }]
                  : [{
                    code: 'memory',
                    kind: 'hard',
                    message: `Needs at least ${requested} MB free memory; this Device has 1024 MB free.`,
                  }],
              },
            ],
          },
        })
      }
      throw new Error(`unexpected POST ${url}`)
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const wizard = useCreateVMWizard(() => {})
    await wizard.loadPickedDevice()
    expect(scoreBodies.some((body) => body.requestedMemoryMB === 1024)).toBe(true)

    const beforeMemory = scoreBodies.length
    wizard.step.value = 2
    wizard.memoryMB.value = 8192
    for (let i = 0; i < 50; i++) {
      if (scoreBodies.length > beforeMemory && scoreBodies.some((body) => body.requestedMemoryMB === 8192)) break
      await nextTick()
      await Promise.resolve()
    }
    expect(scoreBodies.some((body) => body.requestedMemoryMB === 8192)).toBe(true)
    const desk = wizard.deviceOptions.value.find((row) => row.hostId === 'desk')
    expect(desk?.compatible).toBe(false)
    expect(desk?.reasons.some((reason) => reason.includes('8192'))).toBe(true)
    expect(wizard.canProceed()).toBe(false)
    await wizard.submit()
    expect(wizard.error.value).toContain('8192')

    const beforeArch = scoreBodies.length
    wizard.setGuestArch('x86_64')
    for (let i = 0; i < 50; i++) {
      if (scoreBodies.length > beforeArch) break
      await nextTick()
      await Promise.resolve()
    }
    expect(scoreBodies.some((body) => {
      const arches = body.declaredArchitectures
      return Array.isArray(arches) && arches.includes('x86_64')
    })).toBe(true)
  })
})
