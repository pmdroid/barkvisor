import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot } from '../api/types'
import {
  LOG_HISTORY_LIMIT,
  mergeHomeLogRows,
  useDeviceLogsStore,
  type HomeLogRow,
} from './deviceLogs'
import { useLogStore, type LogEntry } from './logs'

const originalGet = api.get
const here = dirname(fileURLToPath(import.meta.url))

function snapshot(
  partial: Partial<HomeDeviceHealthSnapshot> & Pick<HomeDeviceHealthSnapshot, 'hostId' | 'role'>,
): HomeDeviceHealthSnapshot {
  return {
    agentPort: 7778,
    reachability: 'ok',
    ...partial,
  }
}

function entry(partial: Partial<LogEntry> & Pick<LogEntry, 'ts' | 'msg'>): LogEntry {
  return {
    level: 'info',
    cat: 'vm',
    ...partial,
  }
}

function row(hostId: string, log: LogEntry): HomeLogRow {
  return {
    entry: log,
    hostId,
    label: hostId,
    role: hostId === 'self-1' ? 'self' : 'member',
    reachable: true,
  }
}

describe('deviceLogs store (PAS-219)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
    useDeviceLogsStore().clear()
  })

  test('This Device history stays on GET /logs', async () => {
    const self = snapshot({ hostId: 'self-1', role: 'self', displayName: 'agentbox' })
    const get = mock((url: string) => {
      expect(url).toBe('/logs')
      return Promise.resolve({ data: [entry({ ts: '2026-08-17T12:00:00Z', msg: 'local' })] })
    })
    api.get = get as typeof api.get
    const store = useDeviceLogsStore()
    await store.fetchFor(self, { limit: 10 })
    expect(store.entriesFor('self-1')).toHaveLength(1)
    expect(store.homeRows([self])[0]?.label).toBe('agentbox')
    expect(store.homeRows([self])[0]?.role).toBe('self')
    expect(get).toHaveBeenCalledTimes(1)
    expect(useLogStore().entries).toEqual([])
  })

  test('members use logsHistoryFetchPath and skip unreachable Devices', async () => {
    const member = snapshot({ hostId: 'peer/1', role: 'member', displayName: 'orb' })
    const down = snapshot({ hostId: 'peer-2', role: 'member', reachability: 'unreachable' })
    const get = mock((url: string) => {
      expect(url).toBe('/home/devices/peer%2F1/v1/logs')
      return Promise.resolve({ data: [entry({ ts: '2026-08-17T12:00:00Z', msg: 'orb' })] })
    })
    api.get = get as typeof api.get
    const store = useDeviceLogsStore()
    await store.fetchHomeAll([member, down], { limit: 10, level: 'warn' })
    expect(store.homeRows([member, down]).map((item) => item.entry.msg)).toEqual(['orb'])
    expect(store.entriesFor('peer-2')).toEqual([])
    expect(store.errorFor('peer-2')).toBeNull()
    expect(get).toHaveBeenCalledTimes(1)
    expect(get.mock.calls[0]?.[1]).toEqual({ params: { limit: 10, level: 'warn' } })
  })

  test('union merge is newest-first and capped at the existing limit', async () => {
    const self = snapshot({ hostId: 'box', role: 'self', displayName: 'agentbox' })
    const peer = snapshot({ hostId: 'orb', role: 'member', displayName: 'barkvisor-u24' })
    const get = mock((url: string) => {
      if (url === '/logs') {
        return Promise.resolve({
          data: [
            entry({ ts: '2026-08-17T12:00:02Z', msg: 'self-new' }),
            entry({ ts: '2026-08-17T12:00:00Z', msg: 'self-old' }),
          ],
        })
      }
      if (url === '/home/devices/orb/v1/logs') {
        return Promise.resolve({
          data: [entry({ ts: '2026-08-17T12:00:01Z', msg: 'orb-mid' })],
        })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useDeviceLogsStore()
    await store.fetchHomeAll([self, peer], { limit: 1000 })
    const rows = store.homeRows([self, peer], 2)
    expect(rows.map((item) => item.entry.msg)).toEqual(['self-new', 'orb-mid'])
    expect(rows[0]?.role).toBe('self')
    expect(rows[1]?.label).toBe('barkvisor-u24')
    expect(mergeHomeLogRows([
      row('a', entry({ ts: '2026-08-17T12:00:00Z', msg: 'old' })),
      row('b', entry({ ts: '2026-08-17T12:00:02Z', msg: 'new' })),
    ], 1).map((item) => item.entry.msg)).toEqual(['new'])
    expect(mergeHomeLogRows([row('a', entry({ ts: '1', msg: 'x' }))], 0)).toEqual([])
    expect(LOG_HISTORY_LIMIT).toBe(1000)
  })

  test('an unreachable Device omits live rows after a successful fetch', async () => {
    const peer = snapshot({ hostId: 'orb', role: 'member', displayName: 'barkvisor-u24' })
    const get = mock((url: string) => {
      expect(url).toBe('/home/devices/orb/v1/logs')
      return Promise.resolve({ data: [entry({ ts: '2026-08-17T12:00:00Z', msg: 'orb' })] })
    })
    api.get = get as typeof api.get
    const store = useDeviceLogsStore()
    await store.fetchFor(peer)
    expect(store.homeRows([peer])).toHaveLength(1)
    await store.fetchFor({ ...peer, reachability: 'unreachable' })
    expect(get).toHaveBeenCalledTimes(1)
    expect(store.entriesFor('orb')).toEqual([])
    expect(store.homeRows([{ ...peer, reachability: 'unreachable' }])).toEqual([])
    expect(store.errorFor('orb')).toBeNull()
    expect(store.isLoading('orb')).toBe(false)
  })

  test('a failed member fetch does not drop This Device or fail the page', async () => {
    const self = snapshot({ hostId: 'box', role: 'self' })
    const peer = snapshot({ hostId: 'orb', role: 'member' })
    const get = mock((url: string) => {
      if (url === '/logs') {
        return Promise.resolve({ data: [entry({ ts: '2026-08-17T12:00:00Z', msg: 'local' })] })
      }
      if (url === '/home/devices/orb/v1/logs') {
        return Promise.reject(new TypeError('Failed to fetch'))
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useDeviceLogsStore()
    await store.fetchHomeAll([self, peer], { limit: 10 })
    expect(store.homeRows([self, peer]).map((item) => item.entry.msg)).toEqual(['local'])
    expect(store.errorFor('orb')).toBeTruthy()
    expect(store.errorFor('box')).toBeNull()
  })

  test('a stale fetch does not overwrite a newer one', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    let resolveOlder!: (value: { data: LogEntry[] }) => void
    let resolveNewer!: (value: { data: LogEntry[] }) => void
    const older = new Promise<{ data: LogEntry[] }>((resolve) => {
      resolveOlder = resolve
    })
    const newer = new Promise<{ data: LogEntry[] }>((resolve) => {
      resolveNewer = resolve
    })
    const pending = [older, newer]
    let call = 0
    api.get = mock(() => pending[call++]) as typeof api.get
    const store = useDeviceLogsStore()
    const first = store.fetchFor(peer)
    const second = store.fetchFor(peer)
    resolveNewer({ data: [entry({ ts: '2026-08-17T12:00:02Z', msg: 'new' })] })
    await second
    resolveOlder({ data: [entry({ ts: '2026-08-17T12:00:00Z', msg: 'old' })] })
    await first
    expect(store.entriesFor('peer-1').map((item) => item.msg)).toEqual(['new'])
    expect(store.isLoading('peer-1')).toBe(false)
  })

  test('home tail polls reachable members and skips unreachable', async () => {
    const member = snapshot({ hostId: 'peer/1', role: 'member' })
    const down = snapshot({ hostId: 'peer-2', role: 'member', reachability: 'unreachable' })
    const get = mock((url: string) => {
      expect(url).toBe('/home/devices/peer%2F1/v1/logs')
      return Promise.resolve({ data: [entry({ ts: '2026-08-17T12:00:00Z', msg: 'orb' })] })
    })
    api.get = get as typeof api.get
    const store = useDeviceLogsStore()
    expect(store.startHomeTail([member, down], { limit: 10 })).toBe(true)
    expect(get).toHaveBeenCalledTimes(1)
    store.stopHomeTail()
    expect(store.startHomeTail([down])).toBe(false)
  })

  test('an unreachable refresh does not leave loading stuck after a stale list arrives', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    let resolveOlder!: (value: { data: LogEntry[] }) => void
    const older = new Promise<{ data: LogEntry[] }>((resolve) => {
      resolveOlder = resolve
    })
    api.get = mock().mockReturnValueOnce(older) as typeof api.get
    const store = useDeviceLogsStore()
    const first = store.fetchFor(peer)
    expect(store.isLoading('peer-1')).toBe(true)
    await store.fetchFor({ ...peer, reachability: 'unreachable' })
    expect(store.isLoading('peer-1')).toBe(false)
    resolveOlder({ data: [entry({ ts: '2026-08-17T12:00:00Z', msg: 'stale' })] })
    await first
    expect(store.entriesFor('peer-1')).toEqual([])
    expect(store.isLoading('peer-1')).toBe(false)
  })

  test('Logs page unions Devices; Workload-detail logs stay on the PAS-203 store', () => {
    const page = readFileSync(join(here, '../views/LogView.vue'), 'utf8')
    const panel = readFileSync(join(here, '../components/LogsPanel.vue'), 'utf8')
    const detail = readFileSync(join(here, '../stores/logs.ts'), 'utf8')
    expect(page).toContain("from '../stores/deviceLogs'")
    expect(page).toContain('WorkloadDeviceChip')
    expect(page).toContain('All Devices')
    expect(page).toContain('startHomeTail')
    expect(page).not.toContain('cluster')
    expect(page).not.toContain('/api/logs/stream?tunnel')
    expect(panel).toContain("from '../stores/logs'")
    expect(panel).not.toContain('deviceLogs')
    expect(panel).toContain('if (store.startTail(props.device))')
    expect(detail).toContain('logsHistoryFetchPath')
    expect(detail).toContain('shouldPollDeviceControl')
    expect(detail).not.toContain('fetchHomeAll')
  })
})
