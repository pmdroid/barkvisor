import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { HomeDeviceHealthReport } from '../api/types'
import { useDevicesStore } from './devices'
import { canCallMember } from '../utils/memberReachability'

const originalGet = api.get
const originalDelete = api.delete

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
    api.delete = originalDelete
  })

  test('keeps unreachable members in the Home list', async () => {
    api.get = mock(() => Promise.resolve({ data: report })) as typeof api.get
    const store = useDevicesStore()
    await store.fetchHealth({ force: true })
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
    await store.fetchHealth({ force: true })
    expect(store.devices).toHaveLength(2)
    expect(store.error).toBeTruthy()
  })

  test('does not start a second health fetch while one is in flight', async () => {
    let resolveFirst!: (value: { data: HomeDeviceHealthReport }) => void
    const firstResponse = new Promise<{ data: HomeDeviceHealthReport }>((resolve) => {
      resolveFirst = resolve
    })
    const get = mock().mockReturnValueOnce(firstResponse)
    api.get = get as typeof api.get
    const store = useDevicesStore()
    const first = store.fetchHealth()
    const second = store.fetchHealth()
    expect(get).toHaveBeenCalledTimes(1)
    expect(store.loading).toBe(true)
    expect(store.devices).toHaveLength(0)
    resolveFirst({ data: report })
    await second
    await first
    expect(store.devices).toHaveLength(2)
    expect(store.loading).toBe(false)
    expect(store.error).toBeNull()
  })

  test('suppresses offline member hops and resumes them after health recovers', async () => {
    const get = mock()
      .mockResolvedValueOnce({ data: report })
      .mockResolvedValueOnce({
        data: {
          ...report,
          devices: report.devices.map((row) => (
            row.hostId === 'peer-1' ? { ...row, reachability: 'ok', reachabilityError: null } : row
          )),
        },
      })
    api.get = get as typeof api.get
    const store = useDevicesStore()
    await store.fetchHealth()
    expect(canCallMember('peer-1')).toBe(false)
    await store.fetchHealth({ force: true })
    expect(canCallMember('peer-1')).toBe(true)
  })

  test('transport failure marks only the member offline', async () => {
    api.get = mock(() => Promise.resolve({ data: report })) as typeof api.get
    const store = useDevicesStore()
    await store.fetchHealth()
    store.markTransportUnavailable('peer-1')
    expect(store.deviceByHostId('peer-1')?.reachability).toBe('unreachable')
    expect(store.selfDevice?.reachability).toBe('ok')
  })

  test('removes a member from shared state immediately after the API succeeds', async () => {
    api.get = mock(() => Promise.resolve({ data: report })) as typeof api.get
    api.delete = mock(() => Promise.resolve({})) as typeof api.delete
    const store = useDevicesStore()
    await store.fetchHealth()

    await store.removeDevice('peer-1')

    expect(api.delete).toHaveBeenCalledWith('/home/devices/peer-1')
    expect(store.deviceByHostId('peer-1')).toBeNull()
    expect(store.totals?.devices).toBe(1)
    expect(store.totals?.unreachable).toBe(0)
    expect(store.totals?.workloadCount).toBe(2)
  })
})
