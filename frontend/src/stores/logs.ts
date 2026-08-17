import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import { useTicketedEventSource } from '../composables/useTicketedEventSource'
import { logsHistoryFetchPath, shouldPollDeviceControl } from '../utils/editHome'
import type { DeviceApiTarget } from '../utils/homeDeviceApi'

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

export type LogFetchParams = {
  category?: string
  level?: string
  since?: string
  limit?: number
  search?: string
}

export const useLogStore = defineStore('logs', () => {
  const entries = ref<LogEntry[]>([])
  const loading = ref(false)
  const tail = useTicketedEventSource()
  let pollTimer: number | undefined

  async function fetchLogs(
    params: LogFetchParams = {},
    device?: DeviceApiTarget | null,
  ) {
    const path = device ? logsHistoryFetchPath(device) : '/logs'
    if (device && !path) return
    const showLoading = entries.value.length === 0
    if (showLoading) loading.value = true
    try {
      const { data } = await api.get(path ?? '/logs', { params })
      entries.value = Array.isArray(data) ? data : []
    } catch {
      entries.value = []
    } finally {
      if (showLoading) loading.value = false
    }
  }

  function startTail(device?: DeviceApiTarget | null) {
    stopTail()
    if (device && shouldPollDeviceControl(device)) {
      const path = logsHistoryFetchPath(device)
      if (!path) return
      const poll = () => {
        void fetchLogs({ limit: 1000 }, device)
      }
      poll()
      pollTimer = globalThis.setInterval(poll, 4000)
      return
    }
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
    if (pollTimer) {
      clearInterval(pollTimer)
      pollTimer = undefined
    }
    tail.stop()
  }

  function clear() {
    stopTail()
    entries.value = []
  }

  return { entries, loading, fetchLogs, startTail, stopTail, clear }
})
