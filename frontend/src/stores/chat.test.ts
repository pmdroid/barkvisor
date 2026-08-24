import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'

const here = dirname(fileURLToPath(import.meta.url))

const memory = new Map<string, string>()
Object.defineProperty(globalThis, 'localStorage', {
  configurable: true,
  value: {
    getItem(key: string) {
      return memory.has(key) ? memory.get(key)! : null
    },
    setItem(key: string, value: string) {
      memory.set(key, String(value))
    },
    removeItem(key: string) {
      memory.delete(key)
    },
    clear() {
      memory.clear()
    },
  },
})
import type { OllamaHomeCatalog } from '../api/types'
import { useAuthStore } from './auth'
import { useChatStore } from './chat'
import { useOllamaStore } from './ollama'

const originalGet = api.get
const originalPost = api.post

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

describe('chat store (PAS-270)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    localStorage.clear()
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
    localStorage.clear()
  })

  test('hides Chat until the Home catalog has a model', async () => {
    api.get = mock(() => Promise.resolve({ data: reachable })) as typeof api.get
    const ollama = useOllamaStore()
    const chat = useChatStore()
    expect(chat.visible).toBe(false)
    await ollama.fetchCatalog()
    expect(chat.visible).toBe(true)
    expect(chat.model).toBe('llama3:latest')
  })

  test('send streams tokens onto the assistant turn', async () => {
    api.get = mock(() => Promise.resolve({ data: reachable })) as typeof api.get
    localStorage.setItem('token', 'jwt-1')
    const auth = useAuthStore()
    auth.token = 'jwt-1'
    const ollama = useOllamaStore()
    await ollama.fetchCatalog()
    const chat = useChatStore()
    chat.draft = 'hello'
    await chat.send(async (opts) => {
      expect(opts.model).toBe('llama3:latest')
      expect(opts.token).toBe('jwt-1')
      expect(opts.messages).toEqual([{ role: 'user', content: 'hello' }])
      opts.onDelta('Hel')
      opts.onDelta('lo')
    })
    expect(chat.messages.map(({ role, content }) => ({ role, content }))).toEqual([
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: 'Hello' },
    ])
    expect(chat.streaming).toBe(false)
    expect(chat.draft).toBe('')
  })

  test('abort does not leave streaming stuck', async () => {
    api.get = mock(() => Promise.resolve({ data: reachable })) as typeof api.get
    localStorage.setItem('token', 'jwt-1')
    const auth = useAuthStore()
    auth.token = 'jwt-1'
    await useOllamaStore().fetchCatalog()
    const chat = useChatStore()
    chat.draft = 'hello'
    const aborted = Object.assign(new Error('aborted'), { name: 'AbortError' })
    await chat.send(async () => {
      throw aborted
    })
    expect(chat.streaming).toBe(false)
    expect(chat.messages).toHaveLength(2)
  })

  test('late deltas from a stopped send do not land on the next assistant turn', async () => {
    api.get = mock(() => Promise.resolve({ data: reachable })) as typeof api.get
    localStorage.setItem('token', 'jwt-1')
    const auth = useAuthStore()
    auth.token = 'jwt-1'
    await useOllamaStore().fetchCatalog()
    const chat = useChatStore()
    chat.draft = 'first'
    let stale: ((delta: string) => void) | undefined
    let release!: () => void
    const blocked = new Promise<void>((resolve) => {
      release = resolve
    })
    const first = chat.send(async (opts) => {
      stale = opts.onDelta
      await blocked
    })
    chat.stop()
    chat.draft = 'second'
    await chat.send(async (opts) => {
      opts.onDelta('ok')
    })
    stale!('stale')
    release()
    await first
    expect(chat.messages.map(({ role, content }) => ({ role, content }))).toEqual([
      { role: 'user', content: 'first' },
      { role: 'assistant', content: '' },
      { role: 'user', content: 'second' },
      { role: 'assistant', content: 'ok' },
    ])
    expect(chat.streaming).toBe(false)
  })

  test('a late error from a stopped send does not remove the next turn', async () => {
    api.get = mock(() => Promise.resolve({ data: reachable })) as typeof api.get
    localStorage.setItem('token', 'jwt-1')
    const auth = useAuthStore()
    auth.token = 'jwt-1'
    await useOllamaStore().fetchCatalog()
    const chat = useChatStore()
    chat.draft = 'first'
    let release!: (err?: Error) => void
    const blocked = new Promise<void>((_, reject) => {
      release = (err) => reject(err ?? new Error('boom'))
    })
    const first = chat.send(async () => {
      await blocked
    })
    chat.stop()
    chat.draft = 'second'
    await chat.send(async (opts) => {
      opts.onDelta('ok')
    })
    release(new Error('stale'))
    await first.catch(() => undefined)
    expect(chat.messages.map(({ role, content }) => ({ role, content }))).toEqual([
      { role: 'user', content: 'first' },
      { role: 'assistant', content: '' },
      { role: 'user', content: 'second' },
      { role: 'assistant', content: 'ok' },
    ])
    expect(chat.error).toBeNull()
    expect(chat.draft).toBe('')
  })

  test('a failed catalog fetch hides Chat', async () => {
    api.get = mock(() => Promise.reject(new TypeError('Failed to fetch'))) as typeof api.get
    const ollama = useOllamaStore()
    ollama.catalog = reachable
    const chat = useChatStore()
    expect(chat.visible).toBe(true)
    await ollama.fetchCatalog()
    expect(chat.visible).toBe(false)
  })

  test('send retries once after 401 when refresh succeeds', async () => {
    api.get = mock(() => Promise.resolve({ data: reachable })) as typeof api.get
    localStorage.setItem('token', 'jwt-old')
    localStorage.setItem('refreshToken', 'bvrt_abc')
    const auth = useAuthStore()
    auth.token = 'jwt-old'
    auth.refreshToken = 'bvrt_abc'
    api.post = mock((url: string) => {
      expect(url).toBe('/auth/refresh')
      return Promise.resolve({ data: { token: 'jwt-new', refreshToken: 'bvrt_new' } })
    }) as typeof api.post
    await useOllamaStore().fetchCatalog()
    const chat = useChatStore()
    chat.draft = 'hello'
    let calls = 0
    await chat.send(async (opts) => {
      calls += 1
      if (calls === 1) {
        expect(opts.token).toBe('jwt-old')
        const err = new Error('Chat failed (401)') as Error & { status: number }
        err.status = 401
        throw err
      }
      expect(opts.token).toBe('jwt-new')
      opts.onDelta('ok')
    })
    expect(calls).toBe(2)
    expect(chat.messages.map(({ role, content }) => ({ role, content }))).toEqual([
      { role: 'user', content: 'hello' },
      { role: 'assistant', content: 'ok' },
    ])
    expect(chat.streaming).toBe(false)
    expect(chat.error).toBeNull()
  })

  test('iOS WKWebView reuses /chat and localStorage token, never a query JWT', () => {
    const router = readFileSync(join(here, '../router/index.ts'), 'utf8')
    expect(router).toContain("path: '/chat'")
    expect(router).toContain("name: 'chat'")
    expect(router).toContain("import('../views/ChatView.vue')")
    expect(router).toContain('refreshSession')
    const panel = readFileSync(join(here, '../components/ChatPanel.vue'), 'utf8')
    expect(panel).toContain("from '../stores/chat'")
    const auth = readFileSync(join(here, './auth.ts'), 'utf8')
    expect(auth).toContain("localStorage.getItem('token')")
    expect(auth).toContain("localStorage.setItem('token', nextToken)")
    expect(auth).toContain('refreshSession')
    expect(auth).toContain('hydrateFromStorage')
    expect(auth).toContain('barkvisor:session')
    const client = readFileSync(join(here, '../api/client.ts'), 'utf8')
    expect(client).toContain("localStorage.getItem('token')")
    expect(client).toContain('Authorization')
    expect(client).toContain('Bearer')
    expect(client).toContain('refreshAccessToken')
    expect(router).not.toContain('?token=')
    expect(panel).not.toContain('?token=')
  })
})
