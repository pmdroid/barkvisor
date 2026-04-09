import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import api from '../api/client'
import { useLogStore } from './logs'
import { useMetricsStore } from './metrics'

export const useAuthStore = defineStore('auth', () => {
  const token = ref(localStorage.getItem('token') || '')

  const isAuthenticated = computed(() => !!token.value)

  async function login(username: string, password: string) {
    const { data } = await api.post('/auth/login', { username, password })
    token.value = data.token
    localStorage.setItem('token', data.token)
  }

  function logout() {
    useLogStore().clear()
    useMetricsStore().disconnect()
    token.value = ''
    localStorage.removeItem('token')
  }

  return { token, isAuthenticated, login, logout }
})
