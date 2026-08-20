import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { computed, nextTick, ref } from 'vue'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot, Image } from '../api/types'
import { homeImageKey, useHomeLibraryStore } from '../stores/homeLibrary'
import { useDevicesStore } from '../stores/devices'
import { cancelLivePlacementScores, usePlacement } from './usePlacement'
import { PLACEMENT_SCORE_DEBOUNCE_MS } from '../utils/placement'

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

function report(devices: HomeDeviceHealthSnapshot[]) {
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

async function waitMs(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms))
}

async function waitUntil(pred: () => boolean, timeoutMs = 1_000) {
  const start = Date.now()
  while (!pred()) {
    if (Date.now() - start >= timeoutMs) return
    await nextTick()
    await Promise.resolve()
    await waitMs(10)
  }
}

describe('usePlacement (PAS-240)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    api.get = mock(() => Promise.reject(new Error('no default health'))) as typeof api.get
    api.post = mock((url: string) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({ data: { recommendedHostId: null, candidates: [] } })
      }
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post
  })

  afterEach(() => {
    cancelLivePlacementScores()
    api.get = originalGet
    api.post = originalPost
  })

  test('memory edits debounce and abort the in-flight score', async () => {
    const devices = useDevicesStore()
    devices.report = report([device({ hostId: 'desk', role: 'self', displayName: 'desk' })])
    const signals: AbortSignal[] = []
    const scoreBodies: Array<Record<string, unknown>> = []
    const post = mock((url: string, body?: Record<string, unknown>, config?: { signal?: AbortSignal }) => {
      if (url === '/home/placement/score') {
        scoreBodies.push(body ?? {})
        if (config?.signal) signals.push(config.signal)
        return Promise.resolve({ data: { recommendedHostId: 'desk', candidates: [] } })
      }
      throw new Error(`unexpected POST ${url}`)
    })
    api.post = post as typeof api.post

    const memoryMB = ref(1024)
    const placement = usePlacement({
      selectedHostId: ref(''),
      userOverrodeHost: ref(false),
      effectiveGuestArch: computed(() => 'arm64'),
      memoryMB,
      osType: ref('linux'),
      selectedLibraryKey: computed(() => ''),
    })
    await placement.refreshPlacement()
    const afterLoad = scoreBodies.length
    expect(afterLoad).toBeGreaterThan(0)

    memoryMB.value = 2048
    memoryMB.value = 4096
    memoryMB.value = 8192
    await nextTick()
    expect(scoreBodies.length).toBe(afterLoad)

    await waitUntil(
      () => scoreBodies.some((body) => body.requestedMemoryMB === 8192),
      PLACEMENT_SCORE_DEBOUNCE_MS + 400,
    )
    expect(scoreBodies.filter((body) => body.requestedMemoryMB === 8192)).toHaveLength(1)
    expect(scoreBodies.some((body) => body.requestedMemoryMB === 2048)).toBe(false)
    expect(signals.some((signal) => signal.aborted)).toBe(true)
  })

  test('skips a recommended Device that lacks the selected Library image', async () => {
    const devices = useDevicesStore()
    devices.report = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
      device({ hostId: 'studio', role: 'member', displayName: 'studio' }),
    ])
    const img = readyImage({ id: 'iso-1', name: 'ubuntu.iso', arch: 'arm64' })
    const key = homeImageKey(img)
    useHomeLibraryStore().images = [{
      ...img,
      libraryKey: key,
      sourceHostIds: ['desk'],
      copies: [{ hostId: 'desk', imageId: 'desk-iso-1', status: 'ready' }],
    }]
    const post = mock((url: string) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({
          data: {
            recommendedHostId: 'studio',
            candidates: [],
          },
        })
      }
      throw new Error(`unexpected POST ${url}`)
    })
    api.post = post as typeof api.post

    const selectedHostId = ref('')
    const placement = usePlacement({
      selectedHostId,
      userOverrodeHost: ref(false),
      effectiveGuestArch: computed(() => 'arm64'),
      memoryMB: ref(1024),
      osType: ref('linux'),
      selectedLibraryKey: computed(() => key),
    })
    await placement.refreshPlacement()
    expect(selectedHostId.value).toBe('desk')
    expect(placement.consumeProgrammaticHostAssign()).toBe(true)
    expect(placement.consumeProgrammaticHostAssign()).toBe(false)
  })

  test('operator override is not replaced by a later recommendation', async () => {
    const devices = useDevicesStore()
    devices.report = report([
      device({ hostId: 'desk', role: 'self', displayName: 'desk' }),
      device({ hostId: 'studio', role: 'member', displayName: 'studio' }),
    ])
    const selectedHostId = ref('desk')
    const userOverrodeHost = ref(true)
    const post = mock((url: string) => {
      if (url === '/home/placement/score') {
        return Promise.resolve({ data: { recommendedHostId: 'studio', candidates: [] } })
      }
      throw new Error(`unexpected POST ${url}`)
    })
    api.post = post as typeof api.post

    const placement = usePlacement({
      selectedHostId,
      userOverrodeHost,
      effectiveGuestArch: computed(() => 'arm64'),
      memoryMB: ref(1024),
      osType: ref('linux'),
      selectedLibraryKey: computed(() => ''),
    })
    await placement.refreshPlacement(true)
    expect(selectedHostId.value).toBe('desk')
  })
})
