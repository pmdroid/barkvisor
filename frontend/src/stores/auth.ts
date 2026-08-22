import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import api from '../api/client'
import { useLogStore } from './logs'
import { useMetricsStore } from './metrics'

export const REFRESH_TOKEN_KEY = 'refreshToken'

export const useAuthStore = defineStore('auth', () => {
  const token = ref(localStorage.getItem('token') || '')
  const refreshToken = ref(localStorage.getItem(REFRESH_TOKEN_KEY) || '')

  const isAuthenticated = computed(() => !!token.value)

  function persistSession(nextToken: string, nextRefresh: string) {
    token.value = nextToken
    refreshToken.value = nextRefresh
    localStorage.setItem('token', nextToken)
    if (nextRefresh) localStorage.setItem(REFRESH_TOKEN_KEY, nextRefresh)
    else localStorage.removeItem(REFRESH_TOKEN_KEY)
  }

  function clearSessionLocally() {
    useLogStore().clear()
    useMetricsStore().disconnect()
    token.value = ''
    refreshToken.value = ''
    localStorage.removeItem('token')
    localStorage.removeItem(REFRESH_TOKEN_KEY)
  }

  async function login(username: string, password: string) {
    const { data } = await api.post('/auth/login', { username, password })
    if (data?.totpRequired === true && typeof data.challengeToken === 'string') {
      return {
        totpRequired: true as const,
        challengeToken: data.challengeToken,
        challengeExpiresAt: typeof data.challengeExpiresAt === 'string' ? data.challengeExpiresAt : '',
      }
    }
    const nextRefresh = typeof data.refreshToken === 'string' ? data.refreshToken : ''
    persistSession(data.token, nextRefresh)
    return { totpRequired: false as const }
  }

  async function completeLoginChallenge(challengeToken: string, code: string) {
    const { data } = await api.post('/auth/login/challenge', { challengeToken, code })
    const nextRefresh = typeof data.refreshToken === 'string' ? data.refreshToken : ''
    persistSession(data.token, nextRefresh)
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

  return { token, refreshToken, isAuthenticated, login, completeLoginChallenge, logout }
})
