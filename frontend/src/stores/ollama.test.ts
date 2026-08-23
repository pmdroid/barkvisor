import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { OllamaHomeCatalog } from '../api/types'
import { useOllamaStore } from './ollama'

const originalGet = api.get

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

  test('a failed fetch hides Models', async () => {
    api.get = mock(() => Promise.reject(new TypeError('Failed to fetch'))) as typeof api.get
    const store = useOllamaStore()
    await store.fetchCatalog()
    expect(store.anyReachable).toBe(false)
    expect(store.catalog).toBeNull()
  })
})
