import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createPinia, setActivePinia } from 'pinia'
import api, {
  isAuthBootstrapRequest,
  isHomeMemberProxyRequest,
  setUnauthorizedHandler,
} from '../api/client'
import { REFRESH_TOKEN_KEY, useAuthStore } from './auth'

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

const originalPost = api.post

describe('auth store (PAS-242)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    localStorage.clear()
  })

  afterEach(() => {
    api.post = originalPost
    setUnauthorizedHandler(() => undefined)
    localStorage.clear()
  })

  test('login stores the JWT and refresh token', async () => {
    api.post = mock(() =>
      Promise.resolve({ data: { token: 'jwt-1', refreshToken: 'bvrt_abc', role: 'admin' } }),
    ) as typeof api.post

    const store = useAuthStore()
    await store.login('admin', 'secret')
    expect(store.token).toBe('jwt-1')
    expect(store.refreshToken).toBe('bvrt_abc')
    expect(store.role).toBe('admin')
    expect(store.isAdmin).toBe(true)
    expect(localStorage.getItem('token')).toBe('jwt-1')
    expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBe('bvrt_abc')
    expect(localStorage.getItem('userRole')).toBe('admin')
  })

  test('unknown login role fails closed as inference', async () => {
    api.post = mock(() =>
      Promise.resolve({ data: { token: 'jwt-3', refreshToken: 'bvrt_x', role: 'owner' } }),
    ) as typeof api.post

    const store = useAuthStore()
    await store.login('reader', 'secret')
    expect(store.role).toBe('inference')
    expect(store.isAdmin).toBe(false)
  })

  test('login stores an inference role', async () => {
    api.post = mock(() =>
      Promise.resolve({ data: { token: 'jwt-2', refreshToken: 'bvrt_inf', role: 'inference' } }),
    ) as typeof api.post

    const store = useAuthStore()
    await store.login('reader', 'secret')
    expect(store.role).toBe('inference')
    expect(store.isAdmin).toBe(false)
    expect(store.isInference).toBe(true)
    expect(localStorage.getItem('userRole')).toBe('inference')
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

  test('401 interceptor posts logout instead of dropping the refresh token locally', async () => {
    localStorage.setItem('token', 'jwt-1')
    localStorage.setItem(REFRESH_TOKEN_KEY, 'bvrt_abc')
    const store = useAuthStore()
    store.token = 'jwt-1'
    store.refreshToken = 'bvrt_abc'

    const post = mock((url: string, body: unknown) => {
      expect(url).toBe('/auth/logout')
      expect(body).toEqual({ refreshToken: 'bvrt_abc' })
      return Promise.resolve({ status: 204 })
    })
    api.post = post as typeof api.post

    let redirected = 0
    setUnauthorizedHandler(() => {
      redirected += 1
    })

    const reject401 = async (config: { url?: string }) =>
      Promise.reject({
        config,
        response: { status: 401 },
        message: 'unauthorized',
      })
    await api.request({ url: '/vms', adapter: reject401 }).then(
      () => {
        throw new Error('expected 401')
      },
      () => undefined,
    )
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(post).toHaveBeenCalledTimes(1)
    expect(redirected).toBe(1)
    expect(store.refreshToken).toBe('')
    expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBeNull()
  })

  test('login 401 does not revoke a stored refresh family', async () => {
    localStorage.setItem('token', 'jwt-1')
    localStorage.setItem(REFRESH_TOKEN_KEY, 'bvrt_abc')
    const store = useAuthStore()
    store.token = 'jwt-1'
    store.refreshToken = 'bvrt_abc'

    const post = mock((url: string) => {
      expect(url).not.toBe('/auth/logout')
      return Promise.resolve({ status: 204 })
    })
    api.post = post as typeof api.post

    const reject401 = async (config: { url?: string }) =>
      Promise.reject({
        config,
        response: { status: 401 },
        message: 'unauthorized',
      })
    await api
      .request({
        method: 'post',
        url: '/auth/login',
        data: { username: 'admin', password: 'bad' },
        adapter: reject401,
      })
      .then(
        () => {
          throw new Error('expected 401')
        },
        () => undefined,
      )
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(post).not.toHaveBeenCalled()
    expect(store.refreshToken).toBe('bvrt_abc')
    expect(localStorage.getItem(REFRESH_TOKEN_KEY)).toBe('bvrt_abc')
  })

  test('bootstrap auth paths are not treated as session 401s', () => {
    expect(isAuthBootstrapRequest({ url: '/auth/login' })).toBe(true)
    expect(isAuthBootstrapRequest({ url: '/auth/refresh' })).toBe(true)
    expect(isAuthBootstrapRequest({ url: '/auth/logout' })).toBe(true)
    expect(isAuthBootstrapRequest({ url: '/auth/login-offers/redeem' })).toBe(true)
    expect(isAuthBootstrapRequest({ url: '/auth/passkeys/login/begin' })).toBe(true)
    expect(isAuthBootstrapRequest({ url: '/auth/passkeys/login/finish' })).toBe(true)
    expect(isAuthBootstrapRequest({ url: '/auth/login-offers' })).toBe(false)
    expect(isAuthBootstrapRequest({ url: '/auth/passkeys' })).toBe(false)
    expect(isAuthBootstrapRequest({ url: '/vms' })).toBe(false)
  })

  test('member proxy 503 setup_required does not latch local setup', () => {
    expect(isHomeMemberProxyRequest({ url: '/home/devices/peer-1/v1/vms' })).toBe(true)
    expect(isHomeMemberProxyRequest({ url: '/api/home/devices/peer-1/v1/vms' })).toBe(true)
    expect(isHomeMemberProxyRequest({ url: '/vms' })).toBe(false)
    expect(isHomeMemberProxyRequest({ url: '/setup/status' })).toBe(false)
    const client = readFileSync(join(here, '../api/client.ts'), 'utf8')
    expect(client).toContain('!isHomeMemberProxyRequest(error.config)')
    const main = readFileSync(join(here, '../main.ts'), 'utf8')
    expect(main).toContain('clearSetupCache()')
    expect(main).not.toContain('markSetupRequired')
  })

  test('expired JWT guard and 401 interceptor revoke through logout', () => {
    const client = readFileSync(join(here, '../api/client.ts'), 'utf8')
    const router = readFileSync(join(here, '../router/index.ts'), 'utf8')
    expect(client).toContain('revokeRefreshOnUnauthorized')
    expect(client).toContain('useAuthStore().logout()')
    expect(client).not.toMatch(/if \(error\.response\?\.status === 401\) \{\s*localStorage\.removeItem\('token'\)/)
    expect(router).toContain('useAuthStore().logout()')
    expect(router).not.toContain("localStorage.removeItem('refreshToken')")
  })
})
