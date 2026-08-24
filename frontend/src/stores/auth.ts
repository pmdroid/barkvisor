import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import api from '../api/client'
import type { AuthMe, LoginSession, UserRole } from '../api/types'
import { useLogStore } from './logs'
import { useMetricsStore } from './metrics'

export const REFRESH_TOKEN_KEY = 'refreshToken'
export const USER_ROLE_KEY = 'userRole'
export const NATIVE_SESSION_HANDLER = 'barkvisorSession'
export const SESSION_EVENT_NAME = 'barkvisor:session'

function parseRole(raw: unknown): UserRole {
  if (raw === 'admin') return 'admin'
  if (raw === 'inference') return 'inference'
  return 'inference'
}

type NativeSessionBridge = {
  postMessage: (body: { type: string; token?: string; refreshToken?: string }) => void
}

type NativeSessionHost = {
  webkit?: { messageHandlers?: Record<string, NativeSessionBridge | undefined> }
}

const sessionEvents = new EventTarget()
let sessionEpoch = 0
let nativeRefreshWaiters = 0

function nativeSessionBridge(): NativeSessionBridge | null {
  const hosts: NativeSessionHost[] = [globalThis as NativeSessionHost]
  if (typeof window !== 'undefined') hosts.unshift(window as unknown as NativeSessionHost)
  for (const host of hosts) {
    const handler = host.webkit?.messageHandlers?.[NATIVE_SESSION_HANDLER]
    if (handler && typeof handler.postMessage === 'function') return handler
  }
  return null
}

function subscribeSession(listener: () => void): () => void {
  sessionEvents.addEventListener(SESSION_EVENT_NAME, listener)
  if (typeof window !== 'undefined') {
    window.addEventListener(SESSION_EVENT_NAME, listener)
  }
  return () => {
    sessionEvents.removeEventListener(SESSION_EVENT_NAME, listener)
    if (typeof window !== 'undefined') {
      window.removeEventListener(SESSION_EVENT_NAME, listener)
    }
  }
}

/** Tests and the Chat WKWebView script both land here after tokens hit storage. */
export function emitSessionEvent() {
  sessionEvents.dispatchEvent(new Event(SESSION_EVENT_NAME))
  if (typeof window !== 'undefined') {
    window.dispatchEvent(new Event(SESSION_EVENT_NAME))
  }
}

function notifyNativeSession(nextToken: string, nextRefresh: string) {
  const bridge = nativeSessionBridge()
  if (!bridge || !nextToken || !nextRefresh) return
  try {
    bridge.postMessage({ type: 'session', token: nextToken, refreshToken: nextRefresh })
  } catch {
    // Plain browser, or the Chat WKWebView handler is not installed.
  }
}

function requestNativeRefresh(hydrate: () => void): Promise<boolean> {
  const bridge = nativeSessionBridge()
  if (!bridge) return Promise.resolve(false)
  nativeRefreshWaiters += 1
  return new Promise((resolve) => {
    let settled = false
    const finish = (ok: boolean) => {
      if (settled) return
      settled = true
      nativeRefreshWaiters = Math.max(0, nativeRefreshWaiters - 1)
      clearTimeout(timer)
      stop()
      resolve(ok)
    }
    const onSession = () => {
      hydrate()
      finish(!!localStorage.getItem('token') && !!localStorage.getItem(REFRESH_TOKEN_KEY))
    }
    const stop = subscribeSession(onSession)
    const timer = setTimeout(() => finish(false), 8_000)
    try {
      bridge.postMessage({ type: 'refresh' })
    } catch {
      finish(false)
    }
  })
}

export const useAuthStore = defineStore('auth', () => {
  const token = ref(localStorage.getItem('token') || '')
  const refreshToken = ref(localStorage.getItem(REFRESH_TOKEN_KEY) || '')
  const role = ref<UserRole | ''>((localStorage.getItem(USER_ROLE_KEY) as UserRole | null) || '')

  const isAuthenticated = computed(() => !!token.value)
  const isAdmin = computed(() => role.value === 'admin')
  const isInference = computed(() => role.value === 'inference')

  function persistSession(nextToken: string, nextRefresh: string, epoch = sessionEpoch) {
    if (epoch !== sessionEpoch) return
    token.value = nextToken
    refreshToken.value = nextRefresh
    localStorage.setItem('token', nextToken)
    if (nextRefresh) localStorage.setItem(REFRESH_TOKEN_KEY, nextRefresh)
    else localStorage.removeItem(REFRESH_TOKEN_KEY)
    notifyNativeSession(nextToken, nextRefresh)
  }

  /** Pick up access/refresh tokens injected by the iOS Chat WKWebView. */
  function hydrateFromStorage() {
    if (!token.value && !refreshToken.value && nativeRefreshWaiters === 0) return
    const nextToken = localStorage.getItem('token') || ''
    const nextRefresh = localStorage.getItem(REFRESH_TOKEN_KEY) || ''
    if (nextToken !== token.value) token.value = nextToken
    if (nextRefresh !== refreshToken.value) refreshToken.value = nextRefresh
  }

  async function refreshSession(): Promise<boolean> {
    const epoch = sessionEpoch
    hydrateFromStorage()
    if (nativeSessionBridge()) {
      const recovered = await requestNativeRefresh(hydrateFromStorage)
      if (epoch !== sessionEpoch) return false
      return recovered
    }
    const presented = refreshToken.value
    if (!presented) return false
    try {
      const { data } = await api.post<LoginSession>('/auth/refresh', { refreshToken: presented })
      if (epoch !== sessionEpoch) return false
      const nextRefresh =
        typeof data.refreshToken === 'string' && data.refreshToken ? data.refreshToken : presented
      persistSession(data.token, nextRefresh, epoch)
      if (data.role === 'admin' || data.role === 'inference') persistRole(data.role)
      return true
    } catch {
      return false
    }
  }

  subscribeSession(() => {
    hydrateFromStorage()
  })

  function persistRole(next: UserRole) {
    role.value = next
    localStorage.setItem(USER_ROLE_KEY, next)
  }

  function clearSessionLocally() {
    sessionEpoch += 1
    useLogStore().clear()
    useMetricsStore().disconnect()
    token.value = ''
    refreshToken.value = ''
    role.value = ''
    localStorage.removeItem('token')
    localStorage.removeItem(REFRESH_TOKEN_KEY)
    localStorage.removeItem(USER_ROLE_KEY)
  }

  async function fetchMe(): Promise<void> {
    if (!token.value) return
    try {
      const { data } = await api.get<AuthMe>('/auth/me')
      persistRole(parseRole(data.role))
    } catch {
      if (!role.value) persistRole('inference')
    }
  }

  async function login(username: string, password: string) {
    const { data } = await api.post<LoginSession>('/auth/login', { username, password })
    const nextRefresh = typeof data.refreshToken === 'string' ? data.refreshToken : ''
    persistSession(data.token, nextRefresh)
    if (data.role === 'admin' || data.role === 'inference') persistRole(data.role)
    else if (typeof data.role === 'string' && data.role.length > 0) persistRole('inference')
    else await fetchMe()
  }

  async function logout() {
    const access = token.value
    const presented = refreshToken.value
    clearSessionLocally()
    if (!access && !presented) return
    try {
      await api.post(
        '/auth/logout',
        presented ? { refreshToken: presented } : {},
        access ? { headers: { Authorization: `Bearer ${access}` } } : {},
      )
    } catch {
      // Local session is already gone.
    }
  }

  return {
    token,
    refreshToken,
    role,
    isAuthenticated,
    isAdmin,
    isInference,
    login,
    logout,
    fetchMe,
    refreshSession,
    hydrateFromStorage,
  }
})
