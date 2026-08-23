import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import api from '../api/client'
import type { AuthMe, LoginSession, UserRole } from '../api/types'
import { useLogStore } from './logs'
import { useMetricsStore } from './metrics'

export const REFRESH_TOKEN_KEY = 'refreshToken'
export const USER_ROLE_KEY = 'userRole'

function parseRole(raw: unknown): UserRole {
  if (raw === 'admin') return 'admin'
  if (raw === 'inference') return 'inference'
  return 'inference'
}

export const useAuthStore = defineStore('auth', () => {
  const token = ref(localStorage.getItem('token') || '')
  const refreshToken = ref(localStorage.getItem(REFRESH_TOKEN_KEY) || '')
  const role = ref<UserRole | ''>((localStorage.getItem(USER_ROLE_KEY) as UserRole | null) || '')

  const isAuthenticated = computed(() => !!token.value)
  const isAdmin = computed(() => role.value === 'admin')
  const isInference = computed(() => role.value === 'inference')

  function persistSession(nextToken: string, nextRefresh: string) {
    token.value = nextToken
    refreshToken.value = nextRefresh
    localStorage.setItem('token', nextToken)
    if (nextRefresh) localStorage.setItem(REFRESH_TOKEN_KEY, nextRefresh)
    else localStorage.removeItem(REFRESH_TOKEN_KEY)
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
  }
})
