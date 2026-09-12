import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import api from '../api/client'
import type { AuthMe, LoginSession, UserRole } from '../api/types'
import type { AuthMode } from '../utils/authMode'
import {
  applyFrontDoorBypass,
  clearFrontDoorBypass,
  frontDoorAuthMode,
  frontDoorBypassed,
} from '../utils/frontDoor'
import { getPasskey } from '../utils/webauthn'
import { useLogStore } from './logs'
import { useMetricsStore } from './metrics'

export const REFRESH_TOKEN_KEY = 'refreshToken'
export const USER_ROLE_KEY = 'userRole'

function parseRole(raw: unknown): UserRole {
  if (raw === 'admin') return 'admin'
  if (raw === 'inference') return 'inference'
  return 'inference'
}

function syncIngressCookie(value: string) {
  if (typeof document === 'undefined') return
  if (value) document.cookie = `barkvisor=${value}; Path=/; SameSite=Lax`
  else document.cookie = 'barkvisor=; Path=/; Max-Age=0; SameSite=Lax'
}

export const useAuthStore = defineStore('auth', () => {
  const token = ref(localStorage.getItem('token') || '')
  const refreshToken = ref(localStorage.getItem(REFRESH_TOKEN_KEY) || '')
  const role = ref<UserRole | ''>((localStorage.getItem(USER_ROLE_KEY) as UserRole | null) || '')
  const bypassed = frontDoorBypassed
  const authMode = frontDoorAuthMode
  if (token.value) syncIngressCookie(token.value)

  const isAuthenticated = computed(() => bypassed.value || !!token.value)
  const isAdmin = computed(() => bypassed.value || role.value === 'admin')
  const isInference = computed(() => !bypassed.value && role.value === 'inference')

  function persistSession(nextToken: string, nextRefresh: string) {
    token.value = nextToken
    refreshToken.value = nextRefresh
    localStorage.setItem('token', nextToken)
    if (nextRefresh) localStorage.setItem(REFRESH_TOKEN_KEY, nextRefresh)
    else localStorage.removeItem(REFRESH_TOKEN_KEY)
    syncIngressCookie(nextToken)
  }

  function persistRole(next: UserRole) {
    role.value = next
    localStorage.setItem(USER_ROLE_KEY, next)
  }

  function clearSessionLocally() {
    useLogStore().clear()
    useMetricsStore().disconnect()
    token.value = ''
    refreshToken.value = ''
    role.value = ''
    localStorage.removeItem('token')
    localStorage.removeItem(REFRESH_TOKEN_KEY)
    localStorage.removeItem(USER_ROLE_KEY)
    syncIngressCookie('')
  }

  function applyBypass(mode: AuthMode, proxied = false) {
    applyFrontDoorBypass(mode, proxied)
    if (bypassed.value) persistRole('admin')
  }

  function clearBypass() {
    clearFrontDoorBypass()
  }

  async function fetchMe(): Promise<void> {
    if (!token.value && !bypassed.value) return
    try {
      const { data } = await api.get<AuthMe>('/auth/me')
      persistRole(parseRole(data.role))
    } catch {
      if (!role.value) persistRole('inference')
    }
  }

  async function applyLogin(data: LoginSession) {
    const nextRefresh = typeof data.refreshToken === 'string' ? data.refreshToken : ''
    persistSession(data.token, nextRefresh)
    if (data.role === 'admin' || data.role === 'inference') persistRole(data.role)
    else if (typeof data.role === 'string' && data.role.length > 0) persistRole('inference')
    else await fetchMe()
  }

  async function login(username: string, password: string) {
    const { data } = await api.post<LoginSession>('/auth/login', { username, password })
    await applyLogin(data)
  }

  async function loginWithPasskey() {
    const { data: begin } = await api.post<{ sessionId: string; publicKey: Record<string, unknown> }>(
      '/auth/passkeys/login/begin',
      {},
    )
    const credential = await getPasskey(begin.publicKey)
    const { data } = await api.post<LoginSession>('/auth/passkeys/login/finish', {
      sessionId: begin.sessionId,
      credential,
    })
    await applyLogin(data)
  }

  async function logout() {
    if (bypassed.value) return
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
    bypassed,
    authMode,
    isAuthenticated,
    isAdmin,
    isInference,
    login,
    loginWithPasskey,
    logout,
    fetchMe,
    applyBypass,
    clearBypass,
  }
})
