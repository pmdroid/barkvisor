import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot, ImageRepository } from '../api/types'
import { useRepositoryStore } from './repositories'

const originalGet = api.get
const originalPost = api.post

function snapshot(
  partial: Partial<HomeDeviceHealthSnapshot> & Pick<HomeDeviceHealthSnapshot, 'hostId' | 'role'>,
): HomeDeviceHealthSnapshot {
  return {
    agentPort: 7778,
    reachability: 'ok',
    ...partial,
  }
}

function repo(
  partial: Partial<ImageRepository> & Pick<ImageRepository, 'id' | 'url'>,
): ImageRepository {
  return {
    name: 'Built-in',
    isBuiltIn: true,
    repoType: 'templates',
    lastSyncedAt: '2026-01-02T00:00:00Z',
    lastError: null,
    syncStatus: 'idle',
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    ...partial,
  }
}

describe('repository store Home catalog status', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
  })

  test('fetchAll hops members and surfaces lastError on the built-in row', async () => {
    const self = snapshot({ hostId: 'desk', role: 'self', displayName: 'Desk' })
    const peer = snapshot({ hostId: 'studio', role: 'member', displayName: 'Studio' })
    const down = snapshot({
      hostId: 'garage',
      role: 'member',
      displayName: 'Garage',
      reachability: 'unreachable',
    })
    const get = mock((url: string) => {
      if (url === '/repositories') {
        return Promise.resolve({
          data: [repo({ id: 'home-1', url: 'https://example.com/catalog.json' })],
        })
      }
      if (url === '/home/devices/studio/v1/repositories') {
        return Promise.resolve({
          data: [
            repo({
              id: 'studio-1',
              url: 'https://example.com/catalog.json',
              syncStatus: 'error',
              lastError: "data isn't in the correct format",
            }),
          ],
        })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get

    const store = useRepositoryStore()
    await store.fetchAll([self, peer, down])
    expect(get.mock.calls.map((c) => c[0])).toEqual([
      '/repositories',
      '/home/devices/studio/v1/repositories',
    ])
    const row = store.repositories[0]!
    expect(row.deviceSyncs.map((d) => d.hostId)).toEqual(['desk', 'studio', 'garage'])
    expect(row.deviceSyncs.find((d) => d.hostId === 'studio')?.lastError).toBe(
      "data isn't in the correct format",
    )
    expect(row.deviceSyncs.find((d) => d.hostId === 'garage')?.reachable).toBe(false)
    expect(row.deviceSyncs.find((d) => d.hostId === 'garage')?.lastError).toBeTruthy()
  })

  test('a member GET failure is visible without dropping Home catalogs', async () => {
    const self = snapshot({ hostId: 'desk', role: 'self' })
    const peer = snapshot({ hostId: 'studio', role: 'member' })
    const get = mock((url: string) => {
      if (url === '/repositories') {
        return Promise.resolve({
          data: [repo({ id: 'home-1', url: 'https://example.com/catalog.json' })],
        })
      }
      if (url === '/home/devices/studio/v1/repositories') {
        return Promise.reject(new Error('proxy 502'))
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get

    const store = useRepositoryStore()
    await store.fetchAll([self, peer])
    expect(store.error).toBeNull()
    expect(store.repositories).toHaveLength(1)
    expect(store.repositories[0]?.deviceSyncs.find((d) => d.hostId === 'studio')?.lastError).toBe(
      'proxy 502',
    )
  })

  test('Sync fans out through the member proxy by catalog URL', async () => {
    const self = snapshot({ hostId: 'desk', role: 'self' })
    const peer = snapshot({ hostId: 'studio', role: 'member' })
    const get = mock((url: string) => {
      if (url === '/repositories') {
        return Promise.resolve({
          data: [repo({ id: 'home-1', url: 'https://example.com/catalog.json' })],
        })
      }
      if (url === '/home/devices/studio/v1/repositories') {
        return Promise.resolve({
          data: [repo({ id: 'studio-1', url: 'https://example.com/catalog.json' })],
        })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock(() => Promise.resolve({ status: 200, data: {} }))
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const store = useRepositoryStore()
    await store.fetchAll([self, peer])
    await store.sync('home-1')
    expect(post.mock.calls.map((c) => c[0])).toEqual([
      '/repositories/home-1/sync',
      '/home/devices/studio/v1/repositories/studio-1/sync',
    ])
  })

  test('custom catalog Sync stays on Home', async () => {
    const self = snapshot({ hostId: 'desk', role: 'self' })
    const peer = snapshot({ hostId: 'studio', role: 'member' })
    const get = mock((url: string) => {
      if (url === '/repositories') {
        return Promise.resolve({
          data: [
            repo({
              id: 'custom-1',
              url: 'https://mine.example/catalog.json',
              isBuiltIn: false,
            }),
          ],
        })
      }
      if (url === '/home/devices/studio/v1/repositories') {
        return Promise.resolve({
          data: [repo({ id: 'studio-1', url: 'https://example.com/catalog.json' })],
        })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    const post = mock(() => Promise.resolve({ status: 200, data: {} }))
    api.get = get as typeof api.get
    api.post = post as typeof api.post

    const store = useRepositoryStore()
    await store.fetchAll([self, peer])
    await store.sync('custom-1')
    expect(post.mock.calls.map((c) => c[0])).toEqual(['/repositories/custom-1/sync'])
  })
})
