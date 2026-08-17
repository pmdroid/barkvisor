import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import { useMetricsStore } from './metrics'

const originalGet = api.get

describe('metrics store (PAS-203)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
  })

  test('self history stays on /vms/:id/metrics', async () => {
    const get = mock((url: string) => {
      expect(url).toBe('/vms/vm-1/metrics')
      return Promise.resolve({ data: [{ timestamp: '1', cpuPercent: 1, memoryUsedMB: 2, diskReadBytes: 0, diskWriteBytes: 0 }] })
    })
    api.get = get as typeof api.get
    const store = useMetricsStore()
    store.connect('vm-1')
    await Promise.resolve()
    await Promise.resolve()
    expect(get.mock.calls[0]?.[0]).toBe('/vms/vm-1/metrics')
    store.disconnect()
  })

  test('member snapshots poll the Home proxy and skip Upgrade', async () => {
    const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }
    const down = { hostId: 'peer-2', role: 'member', reachability: 'unreachable' }
    const get = mock((url: string) => {
      expect(url).toBe('/home/devices/peer%2F1/v1/vms/vm-9/metrics')
      return Promise.resolve({ data: [{ timestamp: '1', cpuPercent: 4, memoryUsedMB: 8, diskReadBytes: 0, diskWriteBytes: 0 }] })
    })
    api.get = get as typeof api.get
    const store = useMetricsStore()
    store.connect('vm-9', down)
    await Promise.resolve()
    expect(get).not.toHaveBeenCalled()
    store.connect('vm-9', member)
    await Promise.resolve()
    await Promise.resolve()
    expect(get.mock.calls.map((call) => call[0])).toEqual([
      '/home/devices/peer%2F1/v1/vms/vm-9/metrics',
    ])
    store.disconnect()
  })
})
