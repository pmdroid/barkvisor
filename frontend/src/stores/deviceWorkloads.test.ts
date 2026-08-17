import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot, VM } from '../api/types'
import { useDeviceWorkloadsStore } from './deviceWorkloads'

const originalGet = api.get
const originalPost = api.post
const originalPatch = api.patch
const originalDelete = api.delete

function snapshot(partial: Partial<HomeDeviceHealthSnapshot> & Pick<HomeDeviceHealthSnapshot, 'hostId' | 'role'>): HomeDeviceHealthSnapshot {
  return {
    agentPort: 7778,
    reachability: 'ok',
    ...partial,
  }
}

function vm(partial: Partial<VM> & Pick<VM, 'id' | 'name' | 'state'>): VM {
  return {
    vmType: 'linux-arm64',
    cpuCount: 1,
    memoryMB: 512,
    bootDiskId: 'disk-1',
    isoId: null,
    isoIds: null,
    networkId: null,
    cloudInitPath: null,
    description: null,
    bootOrder: null,
    displayResolution: null,
    additionalDiskIds: null,
    uefi: false,
    tpmEnabled: false,
    macAddress: null,
    sharedPaths: null,
    portForwards: null,
    usbDevices: null,
    pendingChanges: false,
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    ...partial,
  }
}

describe('deviceWorkloads store (PAS-52)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
    api.patch = originalPatch
    api.delete = originalDelete
  })

  test('self lists and starts through local /vms', async () => {
    const self = snapshot({ hostId: 'self-1', role: 'self' })
    const listed = [vm({ id: 'vm-1', name: 'home', state: 'stopped' })]
    const started = vm({ id: 'vm-1', name: 'home', state: 'running' })
    const get = mock((url: string) => {
      if (url === '/vms') return Promise.resolve({ data: listed })
      if (url === '/vms/vm-1') return Promise.resolve({ data: started })
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string) => {
      expect(url).toBe('/vms/vm-1/start')
      return Promise.resolve({ data: {} })
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const store = useDeviceWorkloadsStore()
    await store.fetchFor(self)
    expect(store.vmsFor('self-1')).toHaveLength(1)
    await store.start(self, 'vm-1')
    expect(store.vmsFor('self-1')[0]?.state).toBe('running')
    expect(post).toHaveBeenCalledTimes(1)
  })

  test('members list and stop through the Home proxy', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [vm({ id: 'vm-2', name: 'nas', state: 'running' })]
    const stopped = vm({ id: 'vm-2', name: 'nas', state: 'stopped' })
    const get = mock((url: string) => {
      if (url === '/home/devices/peer-1/v1/vms') return Promise.resolve({ data: listed })
      if (url === '/home/devices/peer-1/v1/vms/vm-2') return Promise.resolve({ data: stopped })
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string, body?: unknown) => {
      expect(url).toBe('/home/devices/peer-1/v1/vms/vm-2/stop')
      expect(body).toEqual({ force: false, method: 'acpi' })
      return Promise.resolve({ data: {} })
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const store = useDeviceWorkloadsStore()
    await store.fetchFor(peer)
    await store.stop(peer, 'vm-2')
    expect(store.vmsFor('peer-1')[0]?.state).toBe('stopped')
    expect(get.mock.calls.map((call) => call[0])).toEqual([
      '/home/devices/peer-1/v1/vms',
      '/home/devices/peer-1/v1/vms/vm-2',
    ])
  })

  test('members restart through the Home proxy', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [vm({ id: 'vm-2', name: 'nas', state: 'running' })]
    const restarted = vm({ id: 'vm-2', name: 'nas', state: 'running' })
    const get = mock((url: string) => {
      if (url === '/home/devices/peer-1/v1/vms') return Promise.resolve({ data: listed })
      if (url === '/home/devices/peer-1/v1/vms/vm-2') return Promise.resolve({ data: restarted })
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string) => {
      expect(url).toBe('/home/devices/peer-1/v1/vms/vm-2/restart')
      return Promise.resolve({ data: {} })
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const store = useDeviceWorkloadsStore()
    await store.fetchFor(peer)
    await store.restart(peer, 'vm-2')
    expect(post).toHaveBeenCalledTimes(1)
  })

  test('Home union lists This Device and a member with a Device chip payload', async () => {
    const self = snapshot({ hostId: 'box', role: 'self', displayName: 'agentbox' })
    const peer = snapshot({ hostId: 'orb', role: 'member', displayName: 'barkvisor-u24' })
    const get = mock((url: string) => {
      if (url === '/vms') {
        return Promise.resolve({ data: [vm({ id: 'local-1', name: 'wave1-arch', state: 'stopped' })] })
      }
      if (url === '/home/devices/orb/v1/vms') {
        return Promise.resolve({ data: [vm({ id: 'remote-1', name: 'wave1-ubuntu', state: 'running' })] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useDeviceWorkloadsStore()
    await store.fetchHomeAll([self, peer])
    const rows = store.homeRows([self, peer])
    expect(rows.map((row) => row.vm.name)).toEqual(['wave1-arch', 'wave1-ubuntu'])
    expect(rows[0]?.label).toBe('agentbox')
    expect(rows[0]?.role).toBe('self')
    expect(rows[0]?.reachable).toBe(true)
    expect(rows[1]?.label).toBe('barkvisor-u24')
    expect(rows[1]?.hostId).toBe('orb')
    expect(rows[1]?.reachable).toBe(true)
  })

  test('an unreachable Device keeps last-known Workloads and does not invent new ones', async () => {
    const peer = snapshot({ hostId: 'orb', role: 'member', displayName: 'barkvisor-u24' })
    const get = mock((url: string) => {
      if (url === '/home/devices/orb/v1/vms') {
        return Promise.resolve({ data: [vm({ id: 'remote-1', name: 'wave1-ubuntu', state: 'running' })] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useDeviceWorkloadsStore()
    await store.fetchFor(peer)
    await store.fetchFor({ ...peer, reachability: 'unreachable' })
    expect(get).toHaveBeenCalledTimes(1)
    const rows = store.homeRows([{ ...peer, reachability: 'unreachable' }])
    expect(rows).toHaveLength(1)
    expect(rows[0]?.reachable).toBe(false)
    expect(rows[0]?.vm.name).toBe('wave1-ubuntu')
  })

  test('unreachable members do not invent a Workload list', async () => {
    const get = mock(() => Promise.resolve({ data: [vm({ id: 'ghost', name: 'ghost', state: 'running' })] }))
    api.get = get as typeof api.get
    const store = useDeviceWorkloadsStore()
    await store.fetchFor(snapshot({
      hostId: 'peer-down',
      role: 'member',
      reachability: 'unreachable',
      workloadCount: 4,
    }))
    expect(get).not.toHaveBeenCalled()
    expect(store.vmsFor('peer-down')).toEqual([])
    expect(store.errorFor('peer-down')).toBeNull()
  })

  test('a failed member fetch keeps the previous list and records the error', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [vm({ id: 'vm-2', name: 'nas', state: 'running' })]
    const get = mock()
      .mockResolvedValueOnce({ data: listed })
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
    api.get = get as typeof api.get
    const store = useDeviceWorkloadsStore()
    await store.fetchFor(peer)
    await store.fetchFor(peer)
    expect(store.vmsFor('peer-1')).toHaveLength(1)
    expect(store.errorFor('peer-1')).toBeTruthy()
  })

  test('member GET/PATCH go through the Home proxy and drop targetHostId', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [vm({ id: 'vm-2', name: 'nas', state: 'running', description: 'old' })]
    const patched = vm({ id: 'vm-2', name: 'nas', state: 'running', description: 'desk' })
    const get = mock((url: string) => {
      if (url === '/home/devices/peer-1/v1/vms') return Promise.resolve({ data: listed })
      if (url === '/home/devices/peer-1/v1/vms/vm-2') return Promise.resolve({ data: listed[0] })
      if (url === '/home/devices/peer-1/v1/vms/vm-2/spec') {
        return Promise.resolve({ data: { apiVersion: 'barkvisor.dev/v1', kind: 'Workload' } })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    const patch = mock((url: string, body?: unknown) => {
      expect(url).toBe('/home/devices/peer-1/v1/vms/vm-2')
      expect(body).toEqual({ description: 'desk' })
      expect((body as { targetHostId?: string }).targetHostId).toBeUndefined()
      return Promise.resolve({ data: patched })
    })
    api.get = get as typeof api.get
    api.patch = patch as typeof api.patch
    const store = useDeviceWorkloadsStore()
    await store.fetchFor(peer)
    await store.refreshOne(peer, 'vm-2')
    const spec = await store.fetchSpec(peer, 'vm-2')
    expect(spec.kind).toBe('Workload')
    await store.update(peer, 'vm-2', { description: 'desk', targetHostId: 'foreign' } as never)
    expect(store.vmFor('peer-1', 'vm-2')?.description).toBe('desk')
    expect(get.mock.calls.map((call) => call[0])).toEqual([
      '/home/devices/peer-1/v1/vms',
      '/home/devices/peer-1/v1/vms/vm-2',
      '/home/devices/peer-1/v1/vms/vm-2/spec',
    ])
    expect(patch).toHaveBeenCalledTimes(1)
  })

  test('removeOne evicts a cached member Workload so detail can show not-found', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [vm({ id: 'vm-2', name: 'nas', state: 'running' })]
    api.get = mock((url: string) => {
      if (url === '/home/devices/peer-1/v1/vms') return Promise.resolve({ data: listed })
      throw new Error(`unexpected GET ${url}`)
    }) as typeof api.get
    const store = useDeviceWorkloadsStore()
    await store.fetchFor(peer)
    expect(store.vmFor('peer-1', 'vm-2')?.name).toBe('nas')
    store.removeOne('peer-1', 'vm-2')
    expect(store.vmFor('peer-1', 'vm-2')).toBeUndefined()
    expect(store.vmsFor('peer-1')).toEqual([])
    store.removeOne('peer-1', 'vm-2')
    expect(store.vmsFor('peer-1')).toEqual([])
  })

  test('member USB attach/detach use the Home proxy, never This Device', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const attached = vm({
      id: 'vm-2',
      name: 'nas',
      state: 'stopped',
      usbDevices: [{ vendorId: 'dead', productId: 'beef', deviceId: 'dead:beef' }],
    })
    const detached = vm({ id: 'vm-2', name: 'nas', state: 'stopped', usbDevices: [] })
    const post = mock((url: string, body?: unknown) => {
      expect(url).toBe('/home/devices/peer-1/v1/vms/vm-2/usb')
      expect(body).toEqual({ deviceId: 'dead:beef' })
      return Promise.resolve({ data: attached })
    })
    const del = mock((url: string) => {
      expect(url).toBe('/home/devices/peer-1/v1/vms/vm-2/usb/dead%3Abeef')
      return Promise.resolve({ data: detached })
    })
    api.post = post as typeof api.post
    api.delete = del as typeof api.delete
    const store = useDeviceWorkloadsStore()
    await store.attachUSB(peer, 'vm-2', 'dead:beef')
    expect(store.vmFor('peer-1', 'vm-2')?.usbDevices).toHaveLength(1)
    await store.detachUSB(peer, 'vm-2', 'dead:beef')
    expect(store.vmFor('peer-1', 'vm-2')?.usbDevices).toEqual([])
    expect(post).toHaveBeenCalledTimes(1)
    expect(del).toHaveBeenCalledTimes(1)
  })

  test('an unreachable refresh does not leave loading stuck after a stale list arrives', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    let resolveOlder!: (value: { data: VM[] }) => void
    const older = new Promise<{ data: VM[] }>((resolve) => {
      resolveOlder = resolve
    })
    api.get = mock().mockReturnValueOnce(older) as typeof api.get
    const store = useDeviceWorkloadsStore()
    const first = store.fetchFor(peer)
    expect(store.isLoading('peer-1')).toBe(true)
    await store.fetchFor({ ...peer, reachability: 'unreachable' })
    expect(store.isLoading('peer-1')).toBe(false)
    resolveOlder({ data: [vm({ id: 'vm-stale', name: 'stale', state: 'running' })] })
    await first
    expect(store.vmsFor('peer-1')).toEqual([])
    expect(store.isLoading('peer-1')).toBe(false)
  })

  test('a stale Workload list does not overwrite a newer fetch', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const olderList = [vm({ id: 'vm-old', name: 'old', state: 'running' })]
    const newerList = [vm({ id: 'vm-new', name: 'new', state: 'stopped' })]
    let resolveOlder!: (value: { data: VM[] }) => void
    let resolveNewer!: (value: { data: VM[] }) => void
    const older = new Promise<{ data: VM[] }>((resolve) => {
      resolveOlder = resolve
    })
    const newer = new Promise<{ data: VM[] }>((resolve) => {
      resolveNewer = resolve
    })
    api.get = mock()
      .mockReturnValueOnce(older)
      .mockReturnValueOnce(newer) as typeof api.get
    const store = useDeviceWorkloadsStore()
    const first = store.fetchFor(peer)
    const second = store.fetchFor(peer)
    resolveNewer({ data: newerList })
    await second
    resolveOlder({ data: olderList })
    await first
    expect(store.vmsFor('peer-1').map((row) => row.id)).toEqual(['vm-new'])
    expect(store.isLoading('peer-1')).toBe(false)
    expect(store.errorFor('peer-1')).toBeNull()
  })
})
