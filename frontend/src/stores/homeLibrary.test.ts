import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot, VMTemplate } from '../api/types'
import { useHomeLibraryStore } from './homeLibrary'

const originalGet = api.get

function snapshot(
  partial: Partial<HomeDeviceHealthSnapshot> & Pick<HomeDeviceHealthSnapshot, 'hostId' | 'role'>,
): HomeDeviceHealthSnapshot {
  return {
    agentPort: 7778,
    reachability: 'ok',
    ...partial,
  }
}

function tpl(partial: Partial<VMTemplate> & Pick<VMTemplate, 'id' | 'slug'>): VMTemplate {
  return {
    name: partial.slug,
    description: null,
    category: 'general',
    icon: 'terminal',
    imageSlug: `${partial.slug}-arm64`,
    cpuCount: 1,
    memoryMB: 512,
    diskSizeGB: 8,
    portForwards: null,
    networkMode: 'nat',
    inputs: [],
    userDataTemplate: '',
    isBuiltIn: true,
    repositoryId: 'r1',
    ...partial,
  }
}

describe('homeLibrary store (PAS-34)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
  })

  test('unions templates by slug across Devices and skips unreachable members', async () => {
    const self = snapshot({ hostId: 'desk', role: 'self' })
    const peer = snapshot({ hostId: 'studio', role: 'member' })
    const down = snapshot({ hostId: 'garage', role: 'member', reachability: 'unreachable' })
    const get = mock((url: string) => {
      if (url === '/templates') {
        return Promise.resolve({ data: [tpl({ id: 'local-1', slug: 'ubuntu' }), tpl({ id: 'local-2', slug: 'haos' })] })
      }
      if (url === '/home/devices/studio/v1/templates') {
        return Promise.resolve({ data: [tpl({ id: 'peer-1', slug: 'ubuntu' }), tpl({ id: 'peer-2', slug: 'win' })] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get

    const store = useHomeLibraryStore()
    await store.fetchAll([self, peer, down])
    expect(store.templates.map((t) => t.slug).sort()).toEqual(['haos', 'ubuntu', 'win'])
    expect(store.deviceHasTemplate('ubuntu', 'desk')).toBe(true)
    expect(store.deviceHasTemplate('ubuntu', 'studio')).toBe(true)
    expect(store.deviceHasTemplate('win', 'desk')).toBe(false)
    expect(store.templateForDevice('ubuntu', 'studio')?.id).toBe('peer-1')
    expect(store.deviceHasDeployableTemplate('ubuntu', self)).toBe(true)
    expect(store.deviceHasDeployableTemplate('win', self)).toBe(false)
    expect(store.deviceHasDeployableTemplate('win', peer)).toBe(true)
    const local = tpl({ id: 'local-1', slug: 'ubuntu' })
    expect(store.resolveTemplateForDeploy('ubuntu', peer, local)?.id).toBe('peer-1')
    expect(store.resolveTemplateForDeploy('win', self, local)).toBeNull()
    expect(get.mock.calls.map((c) => c[0])).toEqual([
      '/templates',
      '/home/devices/studio/v1/templates',
    ])
  })

  test('empty library does not treat member Devices as having the local template', () => {
    const store = useHomeLibraryStore()
    const local = tpl({ id: 'local-1', slug: 'ubuntu' })
    const self = snapshot({ hostId: 'desk', role: 'self' })
    const peer = snapshot({ hostId: 'studio', role: 'member' })
    expect(store.templates).toHaveLength(0)
    expect(store.deviceHasDeployableTemplate('ubuntu', self)).toBe(true)
    expect(store.deviceHasDeployableTemplate('ubuntu', peer)).toBe(false)
    expect(store.resolveTemplateForDeploy('ubuntu', peer, local)).toBeNull()
    expect(store.resolveTemplateForDeploy('ubuntu', self, local)?.id).toBe('local-1')
    expect(store.resolveTemplateForDeploy('ubuntu', null, local)?.id).toBe('local-1')
  })

  test('falls back to local /templates when no Devices are listed', async () => {
    const get = mock((url: string) => {
      if (url === '/templates') {
        return Promise.resolve({ data: [tpl({ id: 'local-1', slug: 'ubuntu' })] })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const store = useHomeLibraryStore()
    await store.fetchAll([])
    expect(store.templates).toHaveLength(1)
    expect(store.templates[0]?.slug).toBe('ubuntu')
  })

  test('self still loads when a member GET fails', async () => {
    const self = snapshot({ hostId: 'desk', role: 'self' })
    const peer = snapshot({ hostId: 'studio', role: 'member' })
    const get = mock((url: string) => {
      if (url === '/templates') {
        return Promise.resolve({ data: [tpl({ id: 'local-1', slug: 'ubuntu' })] })
      }
      return Promise.reject(new Error('peer down'))
    })
    api.get = get as typeof api.get

    const store = useHomeLibraryStore()
    await store.fetchAll([self, peer])
    expect(store.templates).toHaveLength(1)
    expect(store.templates[0]?.slug).toBe('ubuntu')
    expect(store.error).toBeNull()
  })
})
