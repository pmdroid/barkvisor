import { defineStore } from 'pinia'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot } from '../api/types'
import { useTicketedEventSource } from '../composables/useTicketedEventSource'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { logsHistoryFetchPath, shouldPollDeviceControl } from '../utils/editHome'
import { isSelfDevice } from '../utils/homeDeviceApi'
import { asArray, createHomeInventory } from './homeInventory'
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
  const inventory = createHomeInventory<LogEntry>()
  const tail = useTicketedEventSource()
  let pollTimer: number | undefined

  function entriesFor(hostId: string): LogEntry[] {
    return inventory.listFor(hostId)
  }

  async function fetchFor(
    device: HomeDeviceHealthSnapshot,
    params: LogFetchParams = {},
  ): Promise<void> {
    const path = logsHistoryFetchPath(device)
    await inventory.fetchFor({
      device,
      canFetch: Boolean(path),
      unreachablePolicy: 'omit',
      loadError: 'Unable to load logs',
      request: async () => {
        const { data } = await api.get(path as string, { params })
        return data
      },
      asList: asArray<LogEntry>,
    })
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
    inventory.replaceList(device.hostId, [entry, ...current].slice(0, cap))
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

    const pollParams: LogFetchParams = {
      ...params,
      limit: params.limit ?? LOG_HISTORY_LIMIT,
    }
    const pollMembers = () => {
      void Promise.all(pollable.map((device) => fetchFor(device, pollParams)))
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
    inventory.clear()
  }

  return {
    entriesByHost: inventory.dataByHost,
    fetchFor,
    fetchHomeAll,
    homeRows,
    entriesFor,
    isLoading: inventory.isLoading,
    errorFor: inventory.errorFor,
    startHomeTail,
    stopHomeTail,
    clear,
  }
})
