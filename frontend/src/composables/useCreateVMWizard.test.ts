import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { nextTick } from 'vue'
import api from '../api/client'
import type { HomeDeviceHealthReport, HomeDeviceHealthSnapshot, Image, SSHKey } from '../api/types'
import { homeImageKey, useHomeLibraryStore } from '../stores/homeLibrary'
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

function readyImage(partial: Partial<Image> & Pick<Image, 'id' | 'name' | 'arch'>): Image {
  return {
    imageType: 'iso',
    status: 'ready',
    sizeBytes: 1,
    sourceUrl: null,
    error: null,
    sha256: null,
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    ...partial,
  }
}

function seedLibraryImage(img: Image, hostIds: string[]): string {
  const store = useHomeLibraryStore()
  const key = homeImageKey(img)
  store.images = [{
    ...img,
    libraryKey: key,
    sourceHostIds: [...hostIds],
    copies: hostIds.map((hostId) => ({ hostId, imageId: `${hostId}-${img.id}` })),
  }]
  return key
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
    return { data: { hostArch: hostId === 'alpha' ? 'x86_64' : 'arm64', hostCpuCount: 4 } }
  }
  if (url === `${prefix}/ssh-keys`) {
    return { data: [sshKey(`key-${hostId}`)] }
  }
  if (url === `${prefix}/images` || url === `${prefix}/networks` || url === `${prefix}/disks`) {
    return { data: [{ id: `${hostId}-res` }] }
  }
  throw new Error(`unexpected GET ${url}`)
}

describe('useCreateVMWizard (PAS-182)', () => {
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

  test('wizard order is Basics → Image → Place → Hardware before Drivers/Storage', () => {
    const wizard = useCreateVMWizard(() => {})
    expect(wizard.stepLabels.value.slice(0, 4)).toEqual(['Basics', 'Image', 'Place', 'Hardware'])
    expect(wizard.stepLabels.value.slice(-3)).toEqual(['Storage', 'Network', 'Summary'])
    expect(wizard.totalSteps.value).toBe(7)
    wizard.selectOS('windows')
    expect(wizard.stepLabels.value).toContain('Drivers')
    expect(wizard.totalSteps.value).toBe(8)
  })

  test('step 1 has no Device picker requirement and Windows stays selectable', () => {
    const wizard = useCreateVMWizard(() => {})
    expect(wizard.currentStepLabel.value).toBe('Basics')
    expect(wizard.canProceed()).toBe(false)
    wizard.name.value = 'intent'
    expect(wizard.canProceed()).toBe(true)
    wizard.selectOS('windows')
    expect(wizard.osType.value).toBe('windows')
    expect(wizard.canProceed()).toBe(true)
  })

  test('no guest arch or placement lecture until an image is selected', () => {
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
    expect(wizard.effectiveGuestArch.value).toBe('')
    const peer = wizard.deviceOptions.value.find((row) => row.hostId === 'box')
    expect(peer?.compatible).toBe(true)
    expect(peer?.reasons.some((reason) => reason.includes('arm64'))).toBe(false)
  })

  test('selecting an image sets effectiveGuestArch and Place reasons from that arch', () => {
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

    const key = seedLibraryImage(
      readyImage({ id: 'iso-1', name: 'ubuntu.iso', arch: 'arm64' }),
      ['desk', 'box'],
    )
    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'desk' })
    wizard.selectedImageId.value = key
    expect(wizard.effectiveGuestArch.value).toBe('arm64')

    const peer = wizard.deviceOptions.value.find((row) => row.hostId === 'box')
    expect(peer?.compatible).toBe(false)
    expect(peer?.reasons.some((reason) => reason.includes('arm64'))).toBe(true)
    expect(peer?.reachable).toBe(true)

    const self = wizard.deviceOptions.value.find((row) => row.hostId === 'desk')
    expect(self?.compatible).toBe(true)
  })

  test('missing local copy is a Place reason and the Device stays pickable', () => {
    const devices = useDevicesStore()
    devices.report = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
      device({
        hostId: 'box',
        role: 'member',
        displayName: 'box',
        platform: { os: 'Linux', arch: 'arm64' },
      }),
    ])
    const key = seedLibraryImage(readyImage({ id: 'iso-1', name: 'ubuntu.iso', arch: 'arm64' }), ['desk'])
    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'desk' })
    wizard.selectedImageId.value = key
    wizard.step.value = 3
    wizard.pickedDeviceLoading.value = false
    wizard.name.value = 'copy'
    const peer = wizard.deviceOptions.value.find((row) => row.hostId === 'box')
    expect(peer?.reasons).toContain("Not in this Device's Library")
    expect(peer?.reachable).toBe(true)
    wizard.selectedHostId.value = 'box'
    expect(wizard.canProceed()).toBe(true)
    expect(wizard.selectedDeviceIncompatibility()).toBe("Not in this Device's Library")
  })

  test('submit rejects a library key when the picked Device has no local copy', async () => {
    const devices = useDevicesStore()
    devices.report = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
      device({
        hostId: 'box',
        role: 'member',
        displayName: 'box',
        platform: { os: 'Linux', arch: 'arm64' },
      }),
    ])
    const key = seedLibraryImage(
      readyImage({ id: 'iso-1', name: 'ubuntu.iso', arch: 'arm64', sha256: 'abc123' }),
      ['desk'],
    )
    const createPosts: Array<{ url: string; body?: Record<string, unknown> }> = []
    const post = mock((url: string, body?: Record<string, unknown>) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({ data: { recommendedHostId: null, candidates: [] } })
      }
      createPosts.push({ url, body })
      throw new Error(`unexpected POST ${url}`)
    })
    api.post = post as typeof api.post

    const wizard = useCreateVMWizard(() => {})
    wizard.selectedImageId.value = key
    wizard.selectedHostId.value = 'box'
    wizard.pickedDeviceLoading.value = false
    wizard.name.value = 'copy'
    await wizard.submit()
    expect(wizard.error.value).toBe("Not in this Device's Library")
    expect(wizard.loading.value).toBe(false)
    expect(createPosts).toEqual([])
  })

  test('submit posts the Device-scoped image id, not the library key', async () => {
    const devices = useDevicesStore()
    devices.report = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
    ])
    const key = seedLibraryImage(
      readyImage({ id: 'iso-1', name: 'ubuntu.iso', arch: 'arm64', sha256: 'abc123' }),
      ['desk'],
    )
    const createPosts: Array<{ url: string; body?: Record<string, unknown> }> = []
    const post = mock((url: string, body?: Record<string, unknown>) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({ data: { recommendedHostId: null, candidates: [] } })
      }
      if (url === '/vms') {
        createPosts.push({ url, body })
        return Promise.resolve({ data: { id: 'vm-1', name: 'copy' } })
      }
      throw new Error(`unexpected POST ${url}`)
    })
    api.post = post as typeof api.post

    let created = false
    const wizard = useCreateVMWizard(() => { created = true })
    wizard.selectedImageId.value = key
    wizard.selectedHostId.value = 'desk'
    wizard.pickedDeviceLoading.value = false
    wizard.name.value = 'copy'
    expect(key.startsWith('sha256:')).toBe(true)
    await wizard.submit()
    expect(wizard.error.value).toBe('')
    expect(createPosts).toHaveLength(1)
    expect(createPosts[0]?.body?.isoId).toBe('desk-iso-1')
    expect(createPosts[0]?.body?.isoId).not.toBe(key)
    expect(created).toBe(true)
  })

  test('placement auto-pick skips a recommended Device that lacks the selected image', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
      device({ hostId: 'studio', role: 'member', displayName: 'studio' }),
    ])
    devices.report = health
    const key = seedLibraryImage(
      readyImage({ id: 'iso-1', name: 'ubuntu.iso', arch: 'arm64' }),
      ['desk'],
    )
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({ data: { hostArch: 'arm64', hostCpuCount: 4 } })
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
    wizard.selectedImageId.value = key
    await wizard.loadPickedDevice()
    expect(wizard.selectedHostId.value).toBe('desk')
    expect(wizard.deviceOptions.value.find((row) => row.hostId === 'studio')?.reasons)
      .toContain("Not in this Device's Library")
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

    const key = seedLibraryImage(readyImage({ id: 'iso-1', name: 'debian.iso', arch: 'x86_64' }), ['box', 'orb'])
    const wizard = useCreateVMWizard(() => {})
    wizard.selectedImageId.value = key
    expect(wizard.effectiveGuestArch.value).toBe('x86_64')

    const self = wizard.deviceOptions.value.find((row) => row.hostId === 'box')
    const peer = wizard.deviceOptions.value.find((row) => row.hostId === 'orb')
    expect(self?.compatible).toBe(true)
    expect(peer?.compatible).toBe(false)
    expect(peer?.reachable).toBe(true)

    wizard.pickedDeviceLoading.value = false
    wizard.step.value = 3
    wizard.name.value = 'anyway'
    wizard.selectedHostId.value = 'orb'
    expect(wizard.canProceed()).toBe(true)
    expect(wizard.selectedDeviceIncompatibility()).toContain('x86_64')
  })

  test('an unreachable Device cannot be placed on', () => {
    const devices = useDevicesStore()
    devices.report = report([
      device({ hostId: 'box', role: 'self', displayName: 'agentbox', platform: { os: 'Linux', arch: 'x86_64' } }),
      device({
        hostId: 'orb',
        role: 'member',
        displayName: 'barkvisor-u24',
        reachability: 'unreachable',
        platform: { os: 'Linux', arch: 'arm64' },
      }),
    ])

    const wizard = useCreateVMWizard(() => {})
    wizard.pickedDeviceLoading.value = false
    wizard.step.value = 3
    wizard.name.value = 'anyway'
    wizard.selectedHostId.value = 'orb'
    const peer = wizard.deviceOptions.value.find((row) => row.hostId === 'orb')
    expect(peer?.reachable).toBe(false)
    expect(wizard.canProceed()).toBe(false)
  })

  test('Basics Next is not blocked by Device inventory; Place is', async () => {
    const wizard = useCreateVMWizard(() => {})
    wizard.name.value = 'vm'
    wizard.pickedDeviceLoading.value = true
    expect(wizard.currentStepLabel.value).toBe('Basics')
    expect(wizard.canProceed()).toBe(true)
    wizard.step.value = 3
    expect(wizard.currentStepLabel.value).toBe('Place')
    expect(wizard.canProceed()).toBe(false)
    await wizard.submit()
    expect(wizard.loading.value).toBe(false)
  })

  test('Hardware CPU max follows pickedCaps, not this Device store', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'alpha', role: 'member', displayName: 'alpha' }),
    ])
    devices.report = health
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url.startsWith('/home/devices/alpha/')) return Promise.resolve(inventoryGet('alpha', url))
      if (url === '/images' || url === '/ssh-keys') return Promise.resolve({ data: [] })
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'alpha' })
    wizard.cpuCount.value = 8
    await wizard.loadPickedDevice()
    expect(wizard.hostCpuCount.value).toBe(4)
    expect(wizard.cpuCount.value).toBeLessThanOrEqual(wizard.hostCpuCount.value)
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
      if (url.startsWith('/home/devices/alpha/') && url.endsWith('/images')) {
        return Promise.resolve(inventoryGet('alpha', url))
      }
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
      if (url.startsWith('/home/devices/alpha/') && url.endsWith('/images')) {
        return Promise.resolve(inventoryGet('alpha', url))
      }
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
        return Promise.resolve({ data: { hostArch: 'arm64', hostCpuCount: 4 } })
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
    wizard.name.value = 'override-vm'
    wizard.step.value = 3
    expect(wizard.canProceed()).toBe(true)
  })

  test('re-scores placement when memory or guest arch changes and still allows place-anyway', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
    ])
    devices.report = health
    const scoreBodies: Array<Record<string, unknown>> = []
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({ data: { hostArch: 'arm64', hostCpuCount: 4 } })
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
    wizard.step.value = 4
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
    wizard.name.value = 'tight-vm'
    expect(wizard.canProceed()).toBe(true)
    expect(wizard.selectedDeviceIncompatibility()).toContain('8192')

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

  test('re-entering Place applies a new recommendation without locking host override', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
      device({ hostId: 'studio', role: 'member', displayName: 'studio' }),
    ])
    devices.report = health
    const img = readyImage({ id: 'iso-1', name: 'ubuntu.iso', arch: 'arm64', sha256: 'reenter' })
    const key = seedLibraryImage(img, ['desk', 'studio'])
    let recommendedHostId = 'studio'
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({ data: { hostArch: 'arm64', hostCpuCount: 4 } })
      }
      if (url === '/images' || url.endsWith('/images')) {
        return Promise.resolve({ data: [{ ...img, id: url.includes('studio') ? 'studio-iso-1' : 'desk-iso-1' }] })
      }
      if (
        url === '/networks' || url === '/disks' || url === '/ssh-keys'
        || url.endsWith('/networks') || url.endsWith('/disks') || url.endsWith('/ssh-keys')
      ) {
        return Promise.resolve({ data: [] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({
          data: {
            recommendedHostId,
            candidates: [
              {
                hostId: recommendedHostId,
                role: recommendedHostId === 'studio' ? 'member' : 'self',
                eligible: true,
                recommended: true,
                rank: 1,
                score: 90,
                reasons: [{ code: 'headroom', kind: 'soft', message: 'ok' }],
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
    wizard.name.value = 'reenter'
    wizard.selectedImageId.value = key
    wizard.next()
    expect(wizard.currentStepLabel.value).toBe('Image')
    wizard.next()
    expect(wizard.currentStepLabel.value).toBe('Place')
    for (let i = 0; i < 50; i++) {
      if (!wizard.pickedDeviceLoading.value && wizard.selectedHostId.value === 'studio') break
      await nextTick()
      await Promise.resolve()
    }
    expect(wizard.selectedHostId.value).toBe('studio')

    recommendedHostId = 'desk'
    wizard.prev()
    expect(wizard.currentStepLabel.value).toBe('Image')
    wizard.next()
    expect(wizard.currentStepLabel.value).toBe('Place')
    for (let i = 0; i < 50; i++) {
      if (!wizard.pickedDeviceLoading.value && wizard.selectedHostId.value === 'desk') break
      await nextTick()
      await Promise.resolve()
    }
    expect(wizard.selectedHostId.value).toBe('desk')

    recommendedHostId = 'studio'
    wizard.prev()
    wizard.next()
    for (let i = 0; i < 50; i++) {
      if (!wizard.pickedDeviceLoading.value && wizard.selectedHostId.value === 'studio') break
      await nextTick()
      await Promise.resolve()
    }
    expect(wizard.selectedHostId.value).toBe('studio')
  })

  test('Image step refreshes Home Library after additional Devices become reachable', async () => {
    const devices = useDevicesStore()
    const desk = device({ hostId: 'desk', role: 'self', displayName: 'desk' })
    const studio = device({ hostId: 'studio', role: 'member', displayName: 'studio' })
    devices.report = report([desk])
    let healthDevices = [desk]
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: report(healthDevices) })
      if (url === '/images') {
        return Promise.resolve({
          data: [readyImage({ id: 'iso-desk', name: 'ubuntu.iso', arch: 'arm64', sha256: 'deskimg' })],
        })
      }
      if (url === '/home/devices/studio/v1/images') {
        return Promise.resolve({
          data: [readyImage({ id: 'iso-studio', name: 'extra.iso', arch: 'arm64', sha256: 'studioimg' })],
        })
      }
      if (url === '/ssh-keys' || url === '/networks' || url === '/disks' || url === '/system/capabilities') {
        return Promise.resolve({ data: url === '/system/capabilities' ? { hostArch: 'arm64', hostCpuCount: 4 } : [] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get

    const wizard = useCreateVMWizard(() => {})
    const library = useHomeLibraryStore()
    healthDevices = [desk, studio]
    wizard.step.value = 2
    expect(wizard.currentStepLabel.value).toBe('Image')
    for (let i = 0; i < 50; i++) {
      if (library.images.some((img) => img.name === 'extra.iso')) break
      await nextTick()
      await Promise.resolve()
    }
    expect(library.images.map((img) => img.name).sort()).toEqual(['extra.iso', 'ubuntu.iso'])
    expect(wizard.filteredImages.value.some((img) => img.name === 'extra.iso')).toBe(true)
  })

  test('loadPickedDevice refreshes Home Library after device health updates', async () => {
    const devices = useDevicesStore()
    const desk = device({ hostId: 'desk', role: 'self', displayName: 'desk' })
    const studio = device({ hostId: 'studio', role: 'member', displayName: 'studio' })
    const img = readyImage({ id: 'iso-1', name: 'ubuntu.iso', arch: 'arm64', sha256: 'shared' })
    const key = seedLibraryImage(img, ['desk'])
    devices.report = report([desk, studio])
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: report([desk, studio]) })
      if (url === '/images') {
        return Promise.resolve({ data: [{ ...img, id: 'desk-iso-1' }] })
      }
      if (url === '/home/devices/studio/v1/images') {
        return Promise.resolve({ data: [{ ...img, id: 'studio-iso-1' }] })
      }
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({ data: { hostArch: 'arm64', hostCpuCount: 4 } })
      }
      if (
        url === '/networks' || url === '/disks' || url === '/ssh-keys'
        || url.endsWith('/networks') || url.endsWith('/disks') || url.endsWith('/ssh-keys')
      ) {
        return Promise.resolve({ data: [] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get

    const library = useHomeLibraryStore()
    expect(library.deviceHasLibraryImage(key, studio)).toBe(false)
    const wizard = useCreateVMWizard(() => {})
    wizard.selectedImageId.value = key
    await wizard.loadPickedDevice()
    for (let i = 0; i < 50; i++) {
      if (library.deviceHasLibraryImage(key, studio)) break
      await nextTick()
      await Promise.resolve()
    }
    expect(library.deviceHasLibraryImage(key, studio)).toBe(true)
  })

  test('Place Next waits for VirtIO status so the Drivers step does not appear mid-advance', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
    ])
    devices.report = health
    const key = seedLibraryImage(
      readyImage({ id: 'iso-win', name: 'windows.iso', arch: 'arm64' }),
      ['desk'],
    )
    let releaseVirtio: (() => void) | undefined
    const virtioGate = new Promise<void>((resolve) => {
      releaseVirtio = resolve
    })
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url === '/system/virtio-win/status' || url.endsWith('/system/virtio-win/status')) {
        return virtioGate.then(() => Promise.resolve({ data: { available: true, imageId: 'virtio-1' } }))
      }
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({ data: { hostArch: 'arm64', hostCpuCount: 4 } })
      }
      if (
        url === '/images' || url === '/networks' || url === '/disks' || url === '/ssh-keys'
        || url.endsWith('/images') || url.endsWith('/networks') || url.endsWith('/disks') || url.endsWith('/ssh-keys')
      ) {
        return Promise.resolve({ data: [] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get

    const wizard = useCreateVMWizard(() => {})
    wizard.name.value = 'win-vm'
    wizard.selectOS('windows')
    wizard.selectedImageId.value = key
    expect(wizard.stepLabels.value).toContain('Drivers')
    wizard.next()
    expect(wizard.currentStepLabel.value).toBe('Image')
    wizard.next()
    expect(wizard.currentStepLabel.value).toBe('Place')
    for (let i = 0; i < 20; i++) {
      await nextTick()
      await Promise.resolve()
    }
    expect(wizard.pickedDeviceLoading.value).toBe(true)
    expect(wizard.canProceed()).toBe(false)
    expect(wizard.virtioWinAvailable.value).toBe(false)
    expect(wizard.stepLabels.value).toContain('Drivers')

    releaseVirtio?.()
    for (let i = 0; i < 50; i++) {
      if (!wizard.pickedDeviceLoading.value && wizard.virtioWinAvailable.value) break
      await nextTick()
      await Promise.resolve()
    }
    expect(wizard.pickedDeviceLoading.value).toBe(false)
    expect(wizard.virtioWinAvailable.value).toBe(true)
    expect(wizard.stepLabels.value).not.toContain('Drivers')
    expect(wizard.totalSteps.value).toBe(7)
    expect(wizard.canProceed()).toBe(true)
    wizard.next()
    expect(wizard.currentStepLabel.value).toBe('Hardware')
  })

  test('Windows vmType follows the selected image architecture', () => {
    const devices = useDevicesStore()
    devices.report = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
    ])
    const library = useHomeLibraryStore()
    const winX86 = readyImage({ id: 'win-x86', name: 'win-x86.iso', arch: 'x86_64' })
    const winArm = readyImage({ id: 'win-arm', name: 'win-arm.iso', arch: 'arm64' })
    library.images = [
      {
        ...winX86,
        libraryKey: homeImageKey(winX86),
        sourceHostIds: ['desk'],
        copies: [{ hostId: 'desk', imageId: 'desk-win-x86' }],
      },
      {
        ...winArm,
        libraryKey: homeImageKey(winArm),
        sourceHostIds: ['desk'],
        copies: [{ hostId: 'desk', imageId: 'desk-win-arm' }],
      },
    ]
    const wizard = useCreateVMWizard(() => {})
    wizard.selectOS('windows')
    wizard.selectedImageId.value = homeImageKey(winX86)
    expect(wizard.effectiveGuestArch.value).toBe('x86_64')
    expect(wizard.vmType.value).toBe('windows-amd64')
    wizard.selectedImageId.value = homeImageKey(winArm)
    expect(wizard.effectiveGuestArch.value).toBe('arm64')
    expect(wizard.vmType.value).toBe('windows-arm64')
  })

  test('submit rejects when the picked Device cannot run the selected image arch', async () => {
    const devices = useDevicesStore()
    const health = report([
      device({ hostId: 'studio', role: 'member', displayName: 'studio' }),
    ])
    devices.report = health
    const img = readyImage({ id: 'win-x86', name: 'win-x86.iso', arch: 'x86_64', sha256: 'winx86' })
    const key = seedLibraryImage(img, ['studio'])
    const createPosts: Array<{ url: string; body?: Record<string, unknown> }> = []
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url === '/home/devices/studio/v1/system/capabilities') {
        return Promise.resolve({ data: { hostArch: 'arm64', hostCpuCount: 4, runnableArches: ['arm64'] } })
      }
      if (url === '/home/devices/studio/v1/images') {
        return Promise.resolve({ data: [{ ...img, id: 'studio-win-x86' }] })
      }
      if (
        url === '/home/devices/studio/v1/networks'
        || url === '/home/devices/studio/v1/disks'
        || url === '/home/devices/studio/v1/ssh-keys'
      ) {
        return Promise.resolve({ data: [] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string, body?: Record<string, unknown>) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({ data: { recommendedHostId: 'studio', candidates: [] } })
      }
      createPosts.push({ url, body })
      throw new Error(`unexpected POST ${url}`)
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const wizard = useCreateVMWizard(() => {}, { initialHostId: 'studio' })
    wizard.selectOS('windows')
    wizard.selectedImageId.value = key
    wizard.name.value = 'win-x86'
    await wizard.loadPickedDevice()
    expect(wizard.hostArch.value).toBe('arm64')
    expect(wizard.effectiveGuestArch.value).toBe('x86_64')
    expect(wizard.vmType.value).toBe('windows-amd64')
    expect(wizard.archProblemText.value).toMatch(/VM architecture \(x86_64\) is not compatible/)
    await wizard.submit()
    expect(wizard.error.value).toMatch(/VM architecture \(x86_64\) is not compatible/)
    expect(wizard.loading.value).toBe(false)
    expect(createPosts).toEqual([])
  })

  test('Place waits for Home Library before scoring and auto-picking', async () => {
    const devices = useDevicesStore()
    const desk = device({ hostId: 'desk', role: 'self', displayName: 'desk' })
    const studio = device({ hostId: 'studio', role: 'member', displayName: 'studio' })
    const health = report([desk, studio])
    devices.report = health
    const img = readyImage({ id: 'iso-1', name: 'ubuntu.iso', arch: 'arm64', sha256: 'shared-lib' })
    const key = seedLibraryImage(img, ['desk'])
    let releaseImages: (() => void) | undefined
    const imageGate = new Promise<void>((resolve) => {
      releaseImages = resolve
    })
    const scorePosts: number[] = []
    const get = mock((url: string) => {
      if (url === '/home/devices/health') return Promise.resolve({ data: health })
      if (url === '/images') {
        return imageGate.then(() => Promise.resolve({ data: [{ ...img, id: 'desk-iso-1' }] }))
      }
      if (url === '/home/devices/studio/v1/images') {
        return imageGate.then(() => Promise.resolve({ data: [{ ...img, id: 'studio-iso-1' }] }))
      }
      if (url === '/system/capabilities' || url.endsWith('/system/capabilities')) {
        return Promise.resolve({ data: { hostArch: 'arm64', hostCpuCount: 4 } })
      }
      if (
        url === '/networks' || url === '/disks' || url === '/ssh-keys'
        || url.endsWith('/networks') || url.endsWith('/disks') || url.endsWith('/ssh-keys')
      ) {
        return Promise.resolve({ data: [] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string) => {
      if (url === '/home/placement/score') {
        scorePosts.push(Date.now())
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
                reasons: [{ code: 'headroom', kind: 'soft', message: 'ok' }],
              },
            ],
          },
        })
      }
      throw new Error(`unexpected POST ${url}`)
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const library = useHomeLibraryStore()
    const wizard = useCreateVMWizard(() => {})
    wizard.selectedImageId.value = key
    wizard.name.value = 'place-lib'
    wizard.step.value = 3
    expect(wizard.currentStepLabel.value).toBe('Place')
    const pending = wizard.loadPickedDevice()
    for (let i = 0; i < 20; i++) {
      if (library.imagesLoading) break
      await nextTick()
      await Promise.resolve()
    }
    expect(library.imagesLoading).toBe(true)
    expect(wizard.canProceed()).toBe(false)
    expect(library.deviceHasLibraryImage(key, studio)).toBe(false)
    expect(wizard.selectedHostId.value).not.toBe('studio')

    releaseImages?.()
    await pending
    expect(library.imagesLoading).toBe(false)
    expect(scorePosts.length).toBeGreaterThan(0)
    expect(library.deviceHasLibraryImage(key, studio)).toBe(true)
    expect(wizard.selectedHostId.value).toBe('studio')
    expect(wizard.canProceed()).toBe(true)
  })
})
