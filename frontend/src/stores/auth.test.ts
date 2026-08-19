import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import { REFRESH_TOKEN_KEY, useAuthStore } from './auth'

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

const originalPost = api.post

describe('auth store (PAS-242)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    localStorage.clear()
  })

  afterEach(() => {
    api.post = originalPost
    localStorage.clear()
  })

  test('login stores the JWT and refresh token', async () => {
    api.post = mock(() =>
      Promise.resolve({ data: { token: 'jwt-1', refreshToken: 'bvrt_abc' } }),
    ) as typeof api.post

    const store = useAuthStore()
    await store.login('admin', 'secret')
    expect(store.token).toBe('jwt-1')
    expect(store.refreshToken).toBe('bvrt_abc')
    expect(localStorage.getItem('token')).toBe('jwt-1')
    expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBe('bvrt_abc')
  })

  test('logout posts the refresh family then clears local session', async () => {
    localStorage.setItem('token', 'jwt-1')
    localStorage.setItem(REFRESH_TOKEN_KEY, 'bvrt_abc')
    const store = useAuthStore()
    store.token = 'jwt-1'
    store.refreshToken = 'bvrt_abc'

    const post = mock((url: string, body: unknown, config?: { headers?: Record<string, string> }) => {
      expect(url).toBe('/auth/logout')
      expect(body).toEqual({ refreshToken: 'bvrt_abc' })
      expect(config?.headers?.Authorization).toBe('Bearer jwt-1')
      expect(localStorage.getItem('token')).toBeNull()
      expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBeNull()
      return Promise.resolve({ status: 204 })
    })
    api.post = post as typeof api.post

    await store.logout()
    expect(store.token).toBe('')
    expect(store.refreshToken).toBe('')
    expect(post).toHaveBeenCalledTimes(1)
  })

  test('logout still clears local session when revoke fails', async () => {
    localStorage.setItem('token', 'jwt-1')
    localStorage.setItem(REFRESH_TOKEN_KEY, 'bvrt_abc')
    const store = useAuthStore()
    store.token = 'jwt-1'
    store.refreshToken = 'bvrt_abc'
    api.post = mock(() => Promise.reject(new Error('offline'))) as typeof api.post

    await store.logout()
    expect(store.token).toBe('')
    expect(store.refreshToken).toBe('')
    expect(localStorage.getItem('token')).toBeNull()
    expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBeNull()
  })
})
