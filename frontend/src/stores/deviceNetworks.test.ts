import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot, HostInterface, Network } from '../api/types'
import { useDeviceNetworksStore } from './deviceNetworks'

const originalGet = api.get
const originalPost = api.post
const originalPatch = api.patch
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

function net(partial: Partial<Network> & Pick<Network, 'id' | 'name' | 'mode'>): Network {
  return {
    isDefault: false,
    ...partial,
  }
}

describe('deviceNetworks store (PAS-216)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
    api.patch = originalPatch
    api.delete = originalDelete
  })

  test('self lists and creates through local /networks', async () => {
    const self = snapshot({ hostId: 'self-1', role: 'self' })
    const listed = [net({ id: 'nat-1', name: 'Default NAT', mode: 'nat', isDefault: true })]
    const created = net({ id: 'lab-1', name: 'lab', mode: 'isolated' })
    const get = mock((url: string) => {
      if (url === '/networks') return Promise.resolve({ data: listed })
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string, body?: unknown) => {
      expect(url).toBe('/networks')
      expect(body).toEqual({ name: 'lab', mode: 'isolated' })
      return Promise.resolve({ data: created })
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const store = useDeviceNetworksStore()
    await store.fetchFor(self)
    expect(store.networksFor('self-1')).toHaveLength(1)
    await store.create(self, { name: 'lab', mode: 'isolated' })
    expect(store.networksFor('self-1').map((row) => row.name)).toEqual(['Default NAT', 'lab'])
    expect(post).toHaveBeenCalledTimes(1)
  })

  test('members list and mutate through the Home proxy', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [net({ id: 'nat-2', name: 'Default NAT', mode: 'nat', isDefault: true })]
    const created = net({ id: 'br-1', name: 'lan', mode: 'bridged', bridge: 'br0' })
    const patched = net({ id: 'br-1', name: 'lan-edit', mode: 'bridged', bridge: 'br0' })
    const get = mock((url: string) => {
      if (url === '/home/devices/peer-1/v1/networks') return Promise.resolve({ data: listed })
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock((url: string, body?: unknown) => {
      expect(url).toBe('/home/devices/peer-1/v1/networks')
      expect(body).toEqual({ name: 'lan', mode: 'bridged', bridge: 'br0' })
      return Promise.resolve({ data: created })
    })
    const patch = mock((url: string, body?: unknown) => {
      expect(url).toBe('/home/devices/peer-1/v1/networks/br-1')
      expect(body).toEqual({ name: 'lan-edit', mode: 'bridged', bridge: 'br0' })
      return Promise.resolve({ data: patched })
    })
    const del = mock((url: string) => {
      expect(url).toBe('/home/devices/peer-1/v1/networks/br-1')
      return Promise.resolve({ data: {} })
    })
    api.get = get as typeof api.get
    api.post = post as typeof api.post
    api.patch = patch as typeof api.patch
    api.delete = del as typeof api.delete

    const store = useDeviceNetworksStore()
    await store.fetchFor(peer)
    await store.create(peer, { name: 'lan', mode: 'bridged', bridge: 'br0' })
    await store.update(peer, 'br-1', { name: 'lan-edit', mode: 'bridged', bridge: 'br0' })
    expect(store.networksFor('peer-1').map((row) => row.name)).toEqual(['Default NAT', 'lan-edit'])
    await store.remove(peer, 'br-1')
    expect(store.networksFor('peer-1').map((row) => row.id)).toEqual(['nat-2'])
    expect(get.mock.calls.map((call) => call[0])).toEqual(['/home/devices/peer-1/v1/networks'])
  })

  test('Home union lists This Device and a member with a Device chip payload', async () => {
    const self = snapshot({ hostId: 'box', role: 'self', displayName: 'agentbox' })
    const peer = snapshot({ hostId: 'orb', role: 'member', displayName: 'barkvisor-u24' })
    const get = mock((url: string) => {
      if (url === '/networks') {
        return Promise.resolve({ data: [net({ id: 'local-1', name: 'Default NAT', mode: 'nat', isDefault: true })] })
      }
      if (url === '/home/devices/orb/v1/networks') {
        return Promise.resolve({ data: [net({ id: 'remote-1', name: 'lan', mode: 'bridged', bridge: 'br0' })] })
      }
      if (url.endsWith('/system/interfaces') || url.endsWith('/system/bridges') || url.endsWith('/system/capabilities')) {
        return Promise.resolve({ data: [] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useDeviceNetworksStore()
    await store.fetchHomeAll([self, peer])
    const rows = store.homeRows([self, peer])
    expect(rows.map((row) => row.network.name)).toEqual(['Default NAT', 'lan'])
    expect(rows[0]?.label).toBe('agentbox')
    expect(rows[0]?.role).toBe('self')
    expect(rows[0]?.reachable).toBe(true)
    expect(rows[1]?.label).toBe('barkvisor-u24')
    expect(rows[1]?.hostId).toBe('orb')
    expect(rows[1]?.reachable).toBe(true)
  })

  test('an unreachable Device keeps last-known names and does not invent new ones', async () => {
    const peer = snapshot({ hostId: 'orb', role: 'member', displayName: 'barkvisor-u24' })
    const get = mock((url: string) => {
      if (url === '/home/devices/orb/v1/networks') {
        return Promise.resolve({ data: [net({ id: 'remote-1', name: 'lan', mode: 'bridged' })] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useDeviceNetworksStore()
    await store.fetchFor(peer)
    await store.fetchFor({ ...peer, reachability: 'unreachable' })
    expect(get).toHaveBeenCalledTimes(1)
    const rows = store.homeRows([{ ...peer, reachability: 'unreachable' }])
    expect(rows).toHaveLength(1)
    expect(rows[0]?.reachable).toBe(false)
    expect(rows[0]?.network.name).toBe('lan')
  })

  test('unreachable members do not invent Default NAT', async () => {
    const get = mock(() => Promise.resolve({
      data: [net({ id: 'ghost', name: 'Default NAT', mode: 'nat', isDefault: true })],
    }))
    api.get = get as typeof api.get
    const store = useDeviceNetworksStore()
    await store.fetchFor(snapshot({
      hostId: 'peer-down',
      role: 'member',
      reachability: 'unreachable',
    }))
    expect(get).not.toHaveBeenCalled()
    expect(store.networksFor('peer-down')).toEqual([])
    expect(store.errorFor('peer-down')).toBeNull()
    expect(store.homeRows([snapshot({
      hostId: 'peer-down',
      role: 'member',
      reachability: 'unreachable',
    })])).toEqual([])
  })

  test('a failed member fetch keeps the previous list and records the error', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const listed = [net({ id: 'nat-2', name: 'Default NAT', mode: 'nat', isDefault: true })]
    const get = mock()
      .mockResolvedValueOnce({ data: listed })
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
    api.get = get as typeof api.get
    const store = useDeviceNetworksStore()
    await store.fetchFor(peer)
    await store.fetchFor(peer)
    expect(store.networksFor('peer-1')).toHaveLength(1)
    expect(store.errorFor('peer-1')).toBeTruthy()
  })

  test('bridged create context uses THAT Device interfaces and capabilities, not Home', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const ifaces: HostInterface[] = [
      { name: 'enp1s0', displayName: 'enp1s0', ipAddress: '10.0.0.9' },
    ]
    const get = mock((url: string) => {
      if (url === '/home/devices/peer-1/v1/system/interfaces') {
        return Promise.resolve({ data: ifaces })
      }
      if (url === '/home/devices/peer-1/v1/system/bridges') {
        return Promise.resolve({ data: [] })
      }
      if (url === '/home/devices/peer-1/v1/system/capabilities') {
        return Promise.resolve({
          data: {
            supportsBridgedNetworking: true,
            supportsManagedBridgeDaemon: false,
            networkModes: [{ mode: 'bridged', supported: true }],
          },
        })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useDeviceNetworksStore()
    await store.fetchContext(peer)
    expect(store.interfacesFor('peer-1').map((row) => row.name)).toEqual(['enp1s0'])
    expect(store.capsFor('peer-1')?.supportsBridgedNetworking).toBe(true)
    expect(get.mock.calls.map((call) => call[0])).toEqual([
      '/home/devices/peer-1/v1/system/interfaces',
      '/home/devices/peer-1/v1/system/bridges',
      '/home/devices/peer-1/v1/system/capabilities',
    ])
    expect(get.mock.calls.some((call) => call[0] === '/system/interfaces')).toBe(false)
    expect(get.mock.calls.some((call) => call[0] === '/system/capabilities')).toBe(false)
  })

  test('an unreachable refresh does not leave loading stuck after a stale list arrives', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    let resolveOlder!: (value: { data: Network[] }) => void
    const older = new Promise<{ data: Network[] }>((resolve) => {
      resolveOlder = resolve
    })
    api.get = mock().mockReturnValueOnce(older) as typeof api.get
    const store = useDeviceNetworksStore()
    const first = store.fetchFor(peer)
    expect(store.isLoading('peer-1')).toBe(true)
    await store.fetchFor({ ...peer, reachability: 'unreachable' })
    expect(store.isLoading('peer-1')).toBe(false)
    resolveOlder({ data: [net({ id: 'stale', name: 'Default NAT', mode: 'nat', isDefault: true })] })
    await first
    expect(store.networksFor('peer-1')).toEqual([])
    expect(store.isLoading('peer-1')).toBe(false)
  })

  test('a stale network list does not overwrite a newer fetch', async () => {
    const peer = snapshot({ hostId: 'peer-1', role: 'member' })
    const olderList = [net({ id: 'old', name: 'old', mode: 'nat' })]
    const newerList = [net({ id: 'new', name: 'new', mode: 'isolated' })]
    let resolveOlder!: (value: { data: Network[] }) => void
    let resolveNewer!: (value: { data: Network[] }) => void
    const older = new Promise<{ data: Network[] }>((resolve) => {
      resolveOlder = resolve
    })
    const newer = new Promise<{ data: Network[] }>((resolve) => {
      resolveNewer = resolve
    })
    api.get = mock()
      .mockReturnValueOnce(older)
      .mockReturnValueOnce(newer) as typeof api.get
    const store = useDeviceNetworksStore()
    const first = store.fetchFor(peer)
    const second = store.fetchFor(peer)
    resolveNewer({ data: newerList })
    await second
    resolveOlder({ data: olderList })
    await first
    expect(store.networksFor('peer-1').map((row) => row.id)).toEqual(['new'])
    expect(store.isLoading('peer-1')).toBe(false)
    expect(store.errorFor('peer-1')).toBeNull()
  })
})
