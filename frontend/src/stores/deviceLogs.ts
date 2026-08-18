import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { HomeDeviceHealthSnapshot } from '../api/types'
import { useTicketedEventSource } from '../composables/useTicketedEventSource'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { logsHistoryFetchPath, shouldPollDeviceControl } from '../utils/editHome'
import { isSelfDevice } from '../utils/homeDeviceApi'
import { type LogEntry, type LogFetchParams } from './logs'

export const LOG_HISTORY_LIMIT = 1000
export const LOG_TAIL_CAP = 2000

export type HomeLogRow = {
  entry: LogEntry
  hostId: string
  label: string
  role: string
  reachable: boolean
}

function asEntries(data: unknown): LogEntry[] {
  return Array.isArray(data) ? (data as LogEntry[]) : []
}

function entryTime(entry: LogEntry): number {
  const parsed = Date.parse(entry.ts)
  return Number.isFinite(parsed) ? parsed : 0
}

/** Newest first, then hostId for a stable tie-break. Cap at the existing page limit. */
export function mergeHomeLogRows(rows: HomeLogRow[], limit: number): HomeLogRow[] {
  const cap = Number.isFinite(limit) ? Math.max(0, limit) : LOG_HISTORY_LIMIT
  return [...rows]
    .sort((a, b) => {
      const delta = entryTime(b.entry) - entryTime(a.entry)
      if (delta !== 0) return delta
      if (a.hostId !== b.hostId) return a.hostId.localeCompare(b.hostId)
      return 0
    })
    .slice(0, cap)
}

export const useDeviceLogsStore = defineStore('deviceLogs', () => {
  const entriesByHost = ref<Record<string, LogEntry[]>>({})
  const loadingByHost = ref<Record<string, boolean>>({})
  const errorByHost = ref<Record<string, string | null>>({})
  const fetchSeqByHost: Record<string, number> = {}
  const tail = useTicketedEventSource()
  let pollTimer: number | undefined

  function entriesFor(hostId: string): LogEntry[] {
    return entriesByHost.value[hostId] ?? []
  }

  function isLoading(hostId: string): boolean {
    return Boolean(loadingByHost.value[hostId])
  }

  function errorFor(hostId: string): string | null {
    return errorByHost.value[hostId] ?? null
  }

  function replaceList(hostId: string, entries: LogEntry[]): void {
    entriesByHost.value = { ...entriesByHost.value, [hostId]: entries }
  }

  function omitHost(hostId: string): void {
    if (entriesByHost.value[hostId]?.length === 0) {
      loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
      return
    }
    replaceList(hostId, [])
  }

  async function fetchFor(
    device: HomeDeviceHealthSnapshot,
    params: LogFetchParams = {},
  ): Promise<void> {
    const hostId = device.hostId
    const seq = (fetchSeqByHost[hostId] ?? 0) + 1
    fetchSeqByHost[hostId] = seq
    const path = logsHistoryFetchPath(device)
    if (!path) {
      // Unreachable: omit live rows. Never fail the whole page (PAS-47).
      omitHost(hostId)
      errorByHost.value = { ...errorByHost.value, [hostId]: null }
      loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
      return
    }
    loadingByHost.value = { ...loadingByHost.value, [hostId]: true }
    try {
      const { data } = await api.get(path, { params })
      if (seq !== fetchSeqByHost[hostId]) return
      replaceList(hostId, asEntries(data))
      errorByHost.value = { ...errorByHost.value, [hostId]: null }
    } catch (err) {
      if (seq !== fetchSeqByHost[hostId]) return
      errorByHost.value = {
        ...errorByHost.value,
        [hostId]: apiErrorMessage(err, 'Unable to load logs'),
      }
    } finally {
      if (seq === fetchSeqByHost[hostId]) {
        loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
      }
    }
  }

  async function fetchHomeAll(
    devices: HomeDeviceHealthSnapshot[],
    params: LogFetchParams = {},
  ): Promise<void> {
    await Promise.all(devices.map((device) => fetchFor(device, params)))
  }

  function homeRows(
    devices: HomeDeviceHealthSnapshot[],
    limit = LOG_HISTORY_LIMIT,
    filters: { hostId?: string; vm?: string } = {},
  ): HomeLogRow[] {
    const scoped = filters.hostId
      ? devices.filter((device) => device.hostId === filters.hostId)
      : devices
    const rows: HomeLogRow[] = []
    for (const device of scoped) {
      if (!logsHistoryFetchPath(device)) continue
      const label = deviceDisplayLabel(device)
      const role = isSelfDevice(device) ? 'self' : String(device.role ?? 'member')
      for (const entry of entriesFor(device.hostId)) {
        if (filters.vm && entry.vm !== filters.vm) continue
        rows.push({
          entry,
          hostId: device.hostId,
          label,
          role,
          reachable: true,
        })
      }
    }
    return mergeHomeLogRows(rows, limit)
  }

  function prependSelf(device: HomeDeviceHealthSnapshot, entry: LogEntry, cap: number): void {
    const current = entriesFor(device.hostId)
    replaceList(device.hostId, [entry, ...current].slice(0, cap))
  }

  function startHomeTail(
    devices: HomeDeviceHealthSnapshot[],
    params: LogFetchParams = {},
  ): boolean {
    stopHomeTail()
    const self = devices.find((device) => isSelfDevice(device)) ?? null
    const members = devices.filter((device) => shouldPollDeviceControl(device))
    const pollable = members.filter((device) => Boolean(logsHistoryFetchPath(device)))
    if (!self && pollable.length === 0) return false

    const pollMembers = () => {
      void Promise.all(
        pollable.map((device) => fetchFor(device, { limit: params.limit ?? LOG_HISTORY_LIMIT })),
      )
    }
    if (pollable.length > 0) {
      pollMembers()
      pollTimer = globalThis.setInterval(pollMembers, 4000)
    }
    if (self) {
      tail.start({
        url: (ticket) => `/api/logs/stream?ticket=${ticket}`,
        reconnect: true,
        onMessage: (event) => {
          try {
            const entry: LogEntry = JSON.parse(event.data)
            prependSelf(self, entry, LOG_TAIL_CAP)
          } catch {
            /* ignore parse errors */
          }
        },
      })
    }
    return true
  }

  function stopHomeTail(): void {
    if (pollTimer) {
      clearInterval(pollTimer)
      pollTimer = undefined
    }
    tail.stop()
  }

  function clear(): void {
    stopHomeTail()
    entriesByHost.value = {}
    loadingByHost.value = {}
    errorByHost.value = {}
    for (const hostId of Object.keys(fetchSeqByHost)) {
      delete fetchSeqByHost[hostId]
    }
  }

  return {
    entriesByHost,
    fetchFor,
    fetchHomeAll,
    homeRows,
    entriesFor,
    isLoading,
    errorFor,
    startHomeTail,
    stopHomeTail,
    clear,
  }
})
