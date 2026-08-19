import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import { useLogStore } from './logs'

const originalGet = api.get

describe('log store (PAS-203)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
  })

  test('self history stays on /logs', async () => {
    const get = mock((url: string) => {
      expect(url).toBe('/logs')
      return Promise.resolve({ data: [{ ts: '1', level: 'info', cat: 'vm', msg: 'ok' }] })
    })
    api.get = get as typeof api.get
    const store = useLogStore()
    await store.fetchLogs({ limit: 10 })
    expect(store.entries).toHaveLength(1)
    expect(get).toHaveBeenCalledTimes(1)
  })

  test('member history uses the Home proxy and skips an unreachable Device', async () => {
    const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }
    const down = { hostId: 'peer-2', role: 'member', reachability: 'unreachable' }
    const get = mock((url: string) => {
      expect(url).toBe('/home/devices/peer%2F1/v1/logs')
      return Promise.resolve({ data: [{ ts: '1', level: 'info', cat: 'vm', msg: 'orb' }] })
    })
    api.get = get as typeof api.get
    const store = useLogStore()
    await store.fetchLogs({ limit: 10 }, member)
    expect(store.entries[0]?.msg).toBe('orb')
    await store.fetchLogs({ limit: 10 }, down)
    expect(store.entries[0]?.msg).toBe('orb')
    expect(get).toHaveBeenCalledTimes(1)
  })

  test('clear drops an in-flight history fetch so it cannot land after a new fetch', async () => {
    let resolveOlder!: (value: { data: unknown[] }) => void
    const older = new Promise<{ data: unknown[] }>((resolve) => {
      resolveOlder = resolve
    })
    const get = mock()
      .mockReturnValueOnce(older)
      .mockResolvedValueOnce({ data: [{ ts: '2', level: 'info', cat: 'vm', msg: 'fresh' }] })
    api.get = get as typeof api.get
    const store = useLogStore()
    const first = store.fetchLogs({ limit: 10 })
    store.clear()
    await store.fetchLogs({ limit: 10 })
    resolveOlder({ data: [{ ts: '1', level: 'info', cat: 'vm', msg: 'stale' }] })
    await first
    expect(store.entries.map((row) => row.msg)).toEqual(['fresh'])
  })

  test('startTail does not flip on for an unreachable member', async () => {
    const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }
    const down = { hostId: 'peer-2', role: 'member', reachability: 'unreachable' }
    const get = mock((url: string) => {
      expect(url).toBe('/home/devices/peer%2F1/v1/logs')
      return Promise.resolve({ data: [{ ts: '1', level: 'info', cat: 'vm', msg: 'orb' }] })
    })
    api.get = get as typeof api.get
    const store = useLogStore()
    expect(store.startTail(down)).toBe(false)
    expect(get).not.toHaveBeenCalled()
    expect(store.startTail(member)).toBe(true)
    expect(get).toHaveBeenCalledTimes(1)
    store.stopTail()
  })
})
