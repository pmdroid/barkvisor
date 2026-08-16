import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { HomeDeviceHealthReport } from '../api/types'
import { useDevicesStore } from './devices'

const originalGet = api.get

const report: HomeDeviceHealthReport = {
  devices: [
    {
      hostId: 'self-1',
      role: 'self',
      displayName: 'desk',
      agentPort: 7778,
      reachability: 'ok',
      platform: { os: 'macos', arch: 'arm64' },
      resources: { cpuCount: 2, memoryTotalMB: 8192, memoryUsedMB: 2048, cpuLoadPercent: 10 },
      workloadCount: 2,
      healthCounts: { running: 1, failed: 1 },
    },
    {
      hostId: 'peer-1',
      role: 'member',
      displayName: null,
      agentHost: '192.168.0.9',
      agentPort: 7778,
      reachability: 'unreachable',
      reachabilityError: 'Device is unreachable',
      resources: null,
      workloadCount: null,
    },
  ],
  totals: {
    devices: 2,
    reachable: 1,
    unreachable: 1,
    workloadCount: 2,
    healthCounts: { running: 1, failed: 1 },
  },
}

describe('devices store (PAS-52)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
  })

  test('keeps unreachable members in the Home list', async () => {
    api.get = mock(() => Promise.resolve({ data: report })) as typeof api.get
    const store = useDevicesStore()
    await store.fetchHealth()
    expect(store.devices).toHaveLength(2)
    expect(store.selfDevice?.hostId).toBe('self-1')
    expect(store.deviceByHostId('peer-1')?.reachability).toBe('unreachable')
    expect(store.deviceLabel(store.devices[1]!)).toBe('peer-1')
    expect(store.totals?.unreachable).toBe(1)
    expect(store.totals?.workloadCount).toBe(2)
    expect(store.error).toBeNull()
  })

  test('a failed health fetch does not drop a previous report', async () => {
    const get = mock()
      .mockResolvedValueOnce({ data: report })
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
    api.get = get as typeof api.get
    const store = useDevicesStore()
    await store.fetchHealth()
    await store.fetchHealth()
    expect(store.devices).toHaveLength(2)
    expect(store.error).toBeTruthy()
  })

  test('a stale health response does not overwrite a newer report', async () => {
    let resolveOlder!: (value: { data: HomeDeviceHealthReport }) => void
    let resolveNewer!: (value: { data: HomeDeviceHealthReport }) => void
    const older = new Promise<{ data: HomeDeviceHealthReport }>((resolve) => {
      resolveOlder = resolve
    })
    const newer = new Promise<{ data: HomeDeviceHealthReport }>((resolve) => {
      resolveNewer = resolve
    })
    api.get = mock()
      .mockReturnValueOnce(older)
      .mockReturnValueOnce(newer) as typeof api.get
    const store = useDevicesStore()
    const first = store.fetchHealth()
    const second = store.fetchHealth()
    const stale: HomeDeviceHealthReport = {
      devices: [report.devices[0]!],
      totals: { ...report.totals, devices: 1, unreachable: 0, reachable: 1 },
    }
    resolveNewer({ data: report })
    await second
    resolveOlder({ data: stale })
    await first
    expect(store.devices).toHaveLength(2)
    expect(store.deviceByHostId('peer-1')?.reachability).toBe('unreachable')
    expect(store.loading).toBe(false)
    expect(store.error).toBeNull()
  })
})
