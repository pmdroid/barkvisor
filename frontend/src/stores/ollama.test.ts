import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { OllamaHomeCatalog } from '../api/types'
import { useOllamaStore } from './ollama'

const originalGet = api.get
const originalPost = api.post
const originalPut = api.put

const reachable: OllamaHomeCatalog = {
  anyReachable: true,
  anyInstalled: true,
  models: [
    {
      name: 'llama3:latest',
      running: true,
      locations: [{ hostId: 'desk', running: true, reachable: true, probedAt: '2026-08-22T00:00:00Z' }],
    },
  ],
  devices: [
    {
      hostId: 'desk',
      displayName: 'desk',
      installed: true,
      reachable: true,
      stale: false,
      installHint: 'brew install ollama',
    },
  ],
}

const hidden: OllamaHomeCatalog = {
  anyReachable: false,
  anyInstalled: false,
  models: [],
  devices: [],
}

describe('ollama store (PAS-269)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
    api.put = originalPut
  })

  test('shows Models when a Device has reachable Ollama', async () => {
    api.get = mock(() => Promise.resolve({ data: reachable })) as typeof api.get
    const store = useOllamaStore()
    await store.fetchCatalog()
    expect(store.anyReachable).toBe(true)
    expect(store.models[0]?.name).toBe('llama3:latest')
  })

  test('hides Models when no Ollama is reachable', async () => {
    api.get = mock(() => Promise.resolve({ data: hidden })) as typeof api.get
    const store = useOllamaStore()
    await store.fetchCatalog()
    expect(store.anyReachable).toBe(false)
    expect(store.models).toEqual([])
  })

  test('start omits hostId so Home picks the Device', async () => {
    const post = mock(() => Promise.resolve({ data: {} }))
    api.post = post as typeof api.post
    const store = useOllamaStore()
    await store.start('llama3:latest')
    expect(post.mock.calls[0]?.[0]).toBe('/home/ollama/start')
    expect(post.mock.calls[0]?.[1]).toEqual({ name: 'llama3:latest' })
  })

  test('start includes hostId when a Device is picked', async () => {
    const post = mock(() => Promise.resolve({ data: {} }))
    api.post = post as typeof api.post
    const store = useOllamaStore()
    await store.start('llama3:latest', 'desk')
    expect(post.mock.calls[0]?.[1]).toEqual({ name: 'llama3:latest', hostId: 'desk' })
  })

  test('saveSettings sends hostId and never stores a raw key', async () => {
    const put = mock(() =>
      Promise.resolve({
        data: {
          hosts: [{ hostId: 'desk', endpoint: 'http://127.0.0.1:11434', hasApiKey: true }],
        },
      }),
    )
    api.put = put as typeof api.put
    const store = useOllamaStore()
    await store.saveSettings({ hostId: 'desk', apiKey: 'secret' })
    expect(put.mock.calls[0]?.[0]).toBe('/home/ollama/settings')
    expect(put.mock.calls[0]?.[1]).toEqual({ hostId: 'desk', apiKey: 'secret' })
    expect(store.settings?.hosts[0]?.hasApiKey).toBe(true)
    expect(store.hostSettings('desk')?.hasApiKey).toBe(true)
    expect(JSON.stringify(store.settings)).not.toContain('secret')
  })

  test('ModelsView copy is Home holds upstream keys per Device', () => {
    const src = readFileSync(
      join(dirname(fileURLToPath(import.meta.url)), '../views/ModelsView.vue'),
      'utf8',
    )
    expect(src).toContain('Home holds upstream keys per')
    expect(src).not.toContain('saved on this Device')
    expect(src).not.toContain('store.settings?.hasApiKey')
  })

  test('a failed fetch hides Models', async () => {
    api.get = mock(() => Promise.reject(new TypeError('Failed to fetch'))) as typeof api.get
    const store = useOllamaStore()
    await store.fetchCatalog()
    expect(store.anyReachable).toBe(false)
    expect(store.catalog).toBeNull()
  })
})
