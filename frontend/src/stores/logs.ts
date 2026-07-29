import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import { useTicketedEventSource } from '../composables/useTicketedEventSource'

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
  const tail = useTicketedEventSource()

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

  function startTail() {
    stopTail()
    tail.start({
      url: (ticket) => `/api/logs/stream?ticket=${ticket}`,
      reconnect: true,
      onMessage: (event) => {
        try {
          const entry: LogEntry = JSON.parse(event.data)
          entries.value.unshift(entry)
          if (entries.value.length > 2000) {
            entries.value = entries.value.slice(0, 2000)
          }
        } catch {
          /* ignore parse errors */
        }
      },
    })
  }

  function stopTail() {
    tail.stop()
  }

  function clear() {
    stopTail()
    entries.value = []
  }

  return { entries, loading, fetchLogs, startTail, stopTail, clear }
})
