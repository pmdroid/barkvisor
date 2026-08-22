import { defineStore } from 'pinia'
import { computed } from 'vue'
import api from '../api/client'
import { useTicketedEventSource } from '../composables/useTicketedEventSource'
import { logsHistoryFetchPath, shouldPollDeviceControl } from '../utils/editHome'
import type { DeviceApiTarget } from '../utils/homeDeviceApi'
import { asArray, createHomeInventory } from './homeInventory'

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

const CURRENT = 'current'

export const useLogStore = defineStore('logs', () => {
  const inventory = createHomeInventory<LogEntry>()
  const tail = useTicketedEventSource()
  let pollTimer: ReturnType<typeof setInterval> | undefined

  const entries = computed(() => inventory.listFor(CURRENT))
  const loading = computed(() => inventory.isLoading(CURRENT))

  async function fetchLogs(
    params: LogFetchParams = {},
    device?: DeviceApiTarget | null,
  ) {
    const path = device ? logsHistoryFetchPath(device) : '/logs'
    if (device && !path) return
    await inventory.fetchFor({
      device: { hostId: CURRENT, role: device?.role ?? 'self', reachability: device?.reachability },
      canFetch: true,
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load logs',
      setLoading: inventory.listFor(CURRENT).length === 0,
      request: async () => {
        const { data } = await api.get(path ?? '/logs', { params })
        return data
      },
      asList: asArray<LogEntry>,
    })
  }

  function startTail(device?: DeviceApiTarget | null): boolean {
    stopTail()
    inventory.invalidateFetch(CURRENT)
    if (device && shouldPollDeviceControl(device)) {
      const path = logsHistoryFetchPath(device)
      if (!path) return false
      const poll = () => {
        void fetchLogs({ limit: 1000 }, device)
      }
      poll()
      pollTimer = globalThis.setInterval(poll, 4000)
      return true
    }
    tail.start({
      url: (ticket) => `/api/logs/stream?ticket=${ticket}`,
      reconnect: true,
      onMessage: (event) => {
        try {
          const entry: LogEntry = JSON.parse(event.data)
          inventory.replaceList(CURRENT, [entry, ...inventory.listFor(CURRENT)].slice(0, 2000))
        } catch {
          /* ignore parse errors */
        }
      },
    })
    return true
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
    inventory.clear()
  }

  return { entries, loading, fetchLogs, startTail, stopTail, clear }
})
