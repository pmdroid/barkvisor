import { defineStore } from 'pinia'
import { ref } from 'vue'
import api, { getWSTicket } from '../api/client'

export interface LogEntry {
  ts: string
  level: 'debug' | 'info' | 'warn' | 'error' | 'fatal'
  cat: string
  msg: string
  vm?: string
  req?: string
  err?: string
  detail?: Record<string, string>
}

export const useLogStore = defineStore('logs', () => {
  const entries = ref<LogEntry[]>([])
  const loading = ref(false)
  let eventSource: EventSource | null = null

  async function fetchLogs(params: {
    category?: string
    level?: string
    since?: string
    limit?: number
    search?: string
  } = {}) {
    loading.value = true
    try {
      const { data } = await api.get('/logs', { params })
      entries.value = data
    } catch {
      entries.value = []
    } finally {
      loading.value = false
    }
  }

  let reconnectTimeout: ReturnType<typeof setTimeout> | null = null
  let reconnectDelay = 1000
  const MAX_RECONNECT_DELAY = 30000
  const MAX_RECONNECT_ATTEMPTS = 10
  let reconnectAttempts = 0

  function startTail() {
    stopTail()
    reconnectDelay = 1000
    reconnectAttempts = 0
    connectTailSSE()
  }

  async function connectTailSSE() {
    let ticket: string
    try {
      ticket = await getWSTicket()
    } catch { return }
    const url = `/api/logs/stream?ticket=${ticket}`
    eventSource = new EventSource(url)
    eventSource.onopen = () => {
      reconnectDelay = 1000
      reconnectAttempts = 0
    }
    eventSource.onmessage = (event) => {
      const entry: LogEntry = JSON.parse(event.data)
      entries.value.unshift(entry)
      if (entries.value.length > 2000) {
        entries.value = entries.value.slice(0, 2000)
      }
    }
    eventSource.onerror = () => {
      eventSource?.close()
      eventSource = null
      reconnectAttempts++
      if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) return
      reconnectTimeout = setTimeout(() => {
        reconnectTimeout = null
        connectTailSSE()
      }, reconnectDelay)
      reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY)
    }
  }

  function stopTail() {
    if (reconnectTimeout) { clearTimeout(reconnectTimeout); reconnectTimeout = null }
    if (eventSource) {
      eventSource.close()
      eventSource = null
    }
  }

  function clear() {
    stopTail()
    entries.value = []
  }

  return { entries, loading, fetchLogs, startTail, stopTail, clear }
})
