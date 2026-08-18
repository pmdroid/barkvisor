import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { Disk, DiskUsage, HomeDeviceHealthSnapshot, StorageSummary } from '../api/types'
import { useDeviceDisksStore } from './deviceDisks'
import { useDiskStore } from './disks'

const originalGet = api.get
const originalPost = api.post
const originalDelete = api.delete

function snapshot(
  partial: Partial<HomeDeviceHealthSnapshot> & Pick<HomeDeviceHealthSnapshot, 'hostId' | 'role'>,
): HomeDeviceHealthSnapshot {
  return {
    agentPort: 7778,
    reachability: 'ok',
    ...partial,
  }
}

function disk(partial: Partial<Disk> & Pick<Disk, 'id' | 'name'>): Disk {
  return {
    path: `/var/lib/barkvisor/disks/${partial.id}.qcow2`,
    sizeBytes: 10 * 1024 * 1024 * 1024,
    format: 'qcow2',
    vmId: null,
    status: 'ready',
    createdAt: '2026-01-01T00:00:00Z',
    ...partial,
  }
}

function usage(partial: Partial<DiskUsage> = {}): DiskUsage {
  return {
    virtualSizeBytes: 10 * 1024 * 1024 * 1024,
    actualSizeBytes: 2 * 1024 * 1024 * 1024,
    ...partial,
  }
}

function summary(partial: Partial<StorageSummary> = {}): StorageSummary {
  return {
    totalVirtualBytes: 10 * 1024 * 1024 * 1024,
    totalActualBytes: 2 * 1024 * 1024 * 1024,
    diskCount: 1,
    volumeTotalBytes: 100 * 1024 * 1024 * 1024,
    volumeAvailableBytes: 80 * 1024 * 1024 * 1024,
    ...partial,
  }
}

describe('deviceDisks store (PAS-218)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
    api.delete = originalDelete
  })

  test('self lists and creates through local /disks', async () => {
    const self = snapshot({ hostId: 'self-1', role: 'self' })
    const listed = [disk({ id: 'boot-1', name: 'boot', vmId: 'vm-1' })]
    const created = disk({ id: 'data-1', name: 'data' })
    const get = mock((url: string) => {
      if (url === '/disks') return Promise.resolve({ data: listed })
      if (url === '/disks/boot-1/usage' || url === '/disks/data-1/usage') {
        return Promise.resolve({ data: usage() })
      }
      if (url === '/disks/summary') return Promise.resolve({ data: summary() })
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string, body?: unknown) => {
      expect(url).toBe('/disks')
      expect(body).toEqual({ name: 'data', sizeGB: 20, format: 'qcow2' })
      return Promise.resolve({ data: created })
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const store = useDeviceDisksStore()
    await store.fetchFor(self)
    expect(store.disksFor('self-1')).toHaveLength(1)
    await store.create(self, { name: 'data', sizeGB: 20, format: 'qcow2' })
    expect(store.disksFor('self-1').map((row) => row.name)).toEqual(['boot', 'data'])
    expect(useDiskStore().disks.map((row) => row.name)).toEqual(['boot', 'data'])
    expect(useDiskStore().disks[0]?.id).toBe('boot-1')
    expect(post).toHaveBeenCalledTimes(1)
  })

  test('self resize and delete also patch diskStore for other surfaces', async () => {
    const self = snapshot({ hostId: 'self-1', role: 'self' })
    const created = disk({ id: 'data-1', name: 'data' })
    const resized = disk({ id: 'data-1', name: 'data', sizeBytes: 30 * 1024 * 1024 * 1024 })
    api.post = mock((url: string) => {
      if (url === '/disks') return Promise.resolve({ data: created })
      if (url === '/disks/data-1/resize') return Promise.resolve({ data: {} })
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post
    api.delete = mock(() => Promise.resolve({ data: {} })) as typeof api.delete
    api.get = mock((url: string) => {
      if (url === '/disks') return Promise.resolve({ data: [resized] })
      if (url === '/disks/data-1/usage') return Promise.resolve({ data: usage() })
      if (url === '/disks/summary') return Promise.resolve({ data: summary({ diskCount: 1 }) })
      throw new Error(`unexpected GET ${url}`)
    }) as typeof api.get

    const home = useDeviceDisksStore()
    const local = useDiskStore()
    await home.create(self, { name: 'data', sizeGB: 10, format: 'qcow2' })
    expect(local.disks.map((row) => row.id)).toEqual(['data-1'])
    await home.resize(self, 'data-1', 30)
    expect(home.disksFor('self-1')[0]?.sizeBytes).toBe(30 * 1024 * 1024 * 1024)
    expect(local.disks[0]?.sizeBytes).toBe(30 * 1024 * 1024 * 1024)
    await home.remove(self, 'data-1')
    expect(local.disks).toEqual([])
    expect(home.disksFor('self-1')).toEqual([])
  })

  test('member mutations do not write into the local diskStore', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const created = disk({ id: 'orb-1', name: 'orb-data' })
    api.post = mock(() => Promise.resolve({ data: created })) as typeof api.post
    api.delete = mock(() => Promise.resolve({ data: {} })) as typeof api.delete
    api.get = mock((url: string) => {
      if (url.endsWith('/usage')) return Promise.resolve({ data: usage() })
      if (url.endsWith('/summary')) return Promise.resolve({ data: summary() })
      throw new Error(`unexpected GET ${url}`)
    }) as typeof api.get

    const home = useDeviceDisksStore()
    const local = useDiskStore()
    local.applyOne(disk({ id: 'keep', name: 'local-boot' }))
    await home.create(peer, { name: 'orb-data', sizeGB: 8, format: 'qcow2' })
    expect(local.disks.map((row) => row.id)).toEqual(['keep'])
    await home.remove(peer, 'orb-1')
    expect(local.disks.map((row) => row.id)).toEqual(['keep'])
  })

  test('members list and mutate through the Home proxy', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [disk({ id: 'boot-2', name: 'boot', vmId: 'vm-9' })]
    const created = disk({ id: 'data-2', name: 'data' })
    const get = mock((url: string) => {
      if (url === '/home/devices/peer-1/v1/disks') return Promise.resolve({ data: listed })
      if (url === '/home/devices/peer-1/v1/disks/boot-2/usage') {
        return Promise.resolve({ data: usage() })
      }
      if (url === '/home/devices/peer-1/v1/disks/data-2/usage') {
        return Promise.resolve({ data: usage() })
      }
      if (url === '/home/devices/peer-1/v1/disks/summary') {
        return Promise.resolve({ data: summary() })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string, body?: unknown) => {
      if (url === '/home/devices/peer-1/v1/disks') {
        expect(body).toEqual({ name: 'data', sizeGB: 12, format: 'raw' })
        return Promise.resolve({ data: created })
      }
      if (url === '/home/devices/peer-1/v1/disks/data-2/resize') {
        expect(body).toEqual({ sizeGB: 24 })
        return Promise.resolve({ data: {} })
      }
      throw new Error(`unexpected POST ${url}`)
    })
    const del = mock((url: string) => {
      expect(url).toBe('/home/devices/peer-1/v1/disks/data-2')
      return Promise.resolve({ data: {} })
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post
    api.delete = del as typeof api.delete

    const store = useDeviceDisksStore()
    await store.fetchFor(peer)
    await store.create(peer, { name: 'data', sizeGB: 12, format: 'raw' })
    expect(store.disksFor('peer-1').map((row) => row.name)).toEqual(['boot', 'data'])
    await store.resize(peer, 'data-2', 24)
    await store.remove(peer, 'data-2')
    expect(store.disksFor('peer-1').map((row) => row.id)).toEqual(['boot-2'])
    expect(get.mock.calls.some((call) => call[0] === '/disks')).toBe(false)
  })

  test('Home union lists This Device and a member with a Device chip payload', async () => {
    const self = snapshot({ hostId: 'box', role: 'self', displayName: 'agentbox' })
    const peer = snapshot({ hostId: 'orb', role: 'member', displayName: 'barkvisor-u24' })
    const get = mock((url: string) => {
      if (url === '/disks') {
        return Promise.resolve({ data: [disk({ id: 'local-1', name: 'boot' })] })
      }
      if (url === '/home/devices/orb/v1/disks') {
        return Promise.resolve({ data: [disk({ id: 'remote-1', name: 'data', vmId: 'vm-orb' })] })
      }
      if (url.endsWith('/usage')) return Promise.resolve({ data: usage() })
      if (url === '/disks/summary') {
        return Promise.resolve({ data: summary({ volumeTotalBytes: 200 * 1024 * 1024 * 1024 }) })
      }
      if (url === '/home/devices/orb/v1/disks/summary') {
        return Promise.resolve({ data: summary({ volumeTotalBytes: 50 * 1024 * 1024 * 1024 }) })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useDeviceDisksStore()
    await store.fetchHomeAll([self, peer])
    const rows = store.homeRows([self, peer])
    expect(rows.map((row) => row.disk.name)).toEqual(['boot', 'data'])
    expect(rows[0]?.label).toBe('agentbox')
    expect(rows[0]?.role).toBe('self')
    expect(rows[0]?.reachable).toBe(true)
    expect(rows[1]?.label).toBe('barkvisor-u24')
    expect(rows[1]?.hostId).toBe('orb')
    expect(rows[1]?.reachable).toBe(true)
    const summaries = store.homeSummaries([self, peer])
    expect(summaries).toHaveLength(2)
    expect(summaries[0]?.summary.volumeTotalBytes).toBe(200 * 1024 * 1024 * 1024)
    expect(summaries[1]?.summary.volumeTotalBytes).toBe(50 * 1024 * 1024 * 1024)
    expect(summaries[0]?.summary.volumeTotalBytes + summaries[1]?.summary.volumeTotalBytes)
      .not.toBe(summaries[0]?.summary.volumeTotalBytes)
  })

  test('an unreachable Device keeps last-known rows and does not invent new ones', async () => {
    const peer = snapshot({ hostId: 'orb', role: 'member', displayName: 'barkvisor-u24' })
    const get = mock((url: string) => {
      if (url === '/home/devices/orb/v1/disks') {
        return Promise.resolve({ data: [disk({ id: 'remote-1', name: 'data' })] })
      }
      if (url.endsWith('/usage')) return Promise.resolve({ data: usage() })
      if (url.endsWith('/summary')) return Promise.resolve({ data: summary() })
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useDeviceDisksStore()
    await store.fetchFor(peer)
    await store.fetchFor({ ...peer, reachability: 'unreachable' })
    expect(get.mock.calls.filter((call) => String(call[0]).endsWith('/disks'))).toHaveLength(1)
    const rows = store.homeRows([{ ...peer, reachability: 'unreachable' }])
    expect(rows).toHaveLength(1)
    expect(rows[0]?.reachable).toBe(false)
    expect(rows[0]?.disk.name).toBe('data')
  })

  test('unreachable members do not invent disks', async () => {
    const get = mock(() => Promise.resolve({
      data: [disk({ id: 'ghost', name: 'boot' })],
    }))
    api.get = get as typeof api.get
    const store = useDeviceDisksStore()
    await store.fetchFor(snapshot({
      hostId: 'peer-down',
      role: 'member',
      reachability: 'unreachable',
    }))
    expect(get).not.toHaveBeenCalled()
    expect(store.disksFor('peer-down')).toEqual([])
    expect(store.errorFor('peer-down')).toBeNull()
    expect(store.homeRows([snapshot({
      hostId: 'peer-down',
      role: 'member',
      reachability: 'unreachable',
    })])).toEqual([])
  })

  test('a failed member fetch keeps the previous list and records the error', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [disk({ id: 'boot-2', name: 'boot' })]
    const get = mock()
      .mockResolvedValueOnce({ data: listed })
      .mockResolvedValueOnce({ data: usage() })
      .mockResolvedValueOnce({ data: summary() })
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
    api.get = get as typeof api.get
    const store = useDeviceDisksStore()
    await store.fetchFor(peer)
    await store.fetchFor(peer)
    expect(store.disksFor('peer-1')).toHaveLength(1)
    expect(store.errorFor('peer-1')).toBeTruthy()
  })

  test('an unreachable refresh does not leave loading stuck after a stale list arrives', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    let resolveOlder!: (value: { data: Disk[] }) => void
    const older = new Promise<{ data: Disk[] }>((resolve) => {
      resolveOlder = resolve
    })
    api.get = mock().mockReturnValueOnce(older) as typeof api.get
    const store = useDeviceDisksStore()
    const first = store.fetchFor(peer)
    expect(store.isLoading('peer-1')).toBe(true)
    await store.fetchFor({ ...peer, reachability: 'unreachable' })
    expect(store.isLoading('peer-1')).toBe(false)
    resolveOlder({ data: [disk({ id: 'stale', name: 'boot' })] })
    await first
    expect(store.disksFor('peer-1')).toEqual([])
    expect(store.isLoading('peer-1')).toBe(false)
  })

  test('a stale fetch does not overwrite a create that finished first', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [disk({ id: 'boot-2', name: 'boot' })]
    const created = disk({ id: 'data-2', name: 'data' })
    let resolveOlder!: (value: { data: Disk[] }) => void
    const older = new Promise<{ data: Disk[] }>((resolve) => {
      resolveOlder = resolve
    })
    api.get = mock((url: string) => {
      if (url.endsWith('/usage')) return Promise.resolve({ data: usage() })
      if (url.endsWith('/summary')) return Promise.resolve({ data: summary() })
      return older
    }) as typeof api.get
    api.post = mock(() => Promise.resolve({ data: created })) as typeof api.post
    const store = useDeviceDisksStore()
    const first = store.fetchFor(peer)
    await store.create(peer, { name: 'data', sizeGB: 12, format: 'qcow2' })
    expect(store.disksFor('peer-1').map((row) => row.id)).toEqual(['data-2'])
    resolveOlder({ data: listed })
    await first
    expect(store.disksFor('peer-1').map((row) => row.id)).toEqual(['data-2'])
    expect(store.isLoading('peer-1')).toBe(false)
  })

  test('a stale disk list does not overwrite a newer fetch', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const olderList = [disk({ id: 'old', name: 'old' })]
    const newerList = [disk({ id: 'new', name: 'new' })]
    let resolveOlder!: (value: { data: Disk[] }) => void
    let resolveNewer!: (value: { data: Disk[] }) => void
    const older = new Promise<{ data: Disk[] }>((resolve) => {
      resolveOlder = resolve
    })
    const newer = new Promise<{ data: Disk[] }>((resolve) => {
      resolveNewer = resolve
    })
    api.get = mock((url: string) => {
      if (url.endsWith('/usage')) return Promise.resolve({ data: usage() })
      if (url.endsWith('/summary')) return Promise.resolve({ data: summary() })
      if (url === '/home/devices/peer-1/v1/disks') {
        return urlCalls()
      }
      throw new Error(`unexpected GET ${url}`)
    }) as typeof api.get

    const pending = [older, newer]
    let call = 0
    function urlCalls() {
      return pending[call++]
    }

    const store = useDeviceDisksStore()
    const first = store.fetchFor(peer)
    const second = store.fetchFor(peer)
    resolveNewer({ data: newerList })
    await second
    resolveOlder({ data: olderList })
    await first
    expect(store.disksFor('peer-1').map((row) => row.id)).toEqual(['new'])
    expect(store.isLoading('peer-1')).toBe(false)
    expect(store.errorFor('peer-1')).toBeNull()
  })
})
