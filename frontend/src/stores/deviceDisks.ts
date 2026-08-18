import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { Disk, DiskUsage, HomeDeviceHealthSnapshot, StorageSummary } from '../api/types'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import {
  canCallDeviceAPI,
  deviceDiskPath,
  deviceDiskResizePath,
  deviceDiskSummaryPath,
  deviceDiskUsagePath,
  deviceDisksPath,
  isSelfDevice,
} from '../utils/homeDeviceApi'
import { useDiskStore } from './disks'

export type DiskWriteBody = {
  name: string
  sizeGB: number
  format: string
}

export type HomeDiskRow = {
  disk: Disk
  hostId: string
  label: string
  role: string
  reachable: boolean
}

export type HomeDiskSummary = {
  hostId: string
  label: string
  role: string
  reachable: boolean
  summary: StorageSummary
}

function asDisks(data: unknown): Disk[] {
  return Array.isArray(data) ? (data as Disk[]) : []
}

export const useDeviceDisksStore = defineStore('deviceDisks', () => {
  const disksByHost = ref<Record<string, Disk[]>>({})
  const usagesByHost = ref<Record<string, Record<string, DiskUsage>>>({})
  const summaryByHost = ref<Record<string, StorageSummary>>({})
  const loadingByHost = ref<Record<string, boolean>>({})
  const errorByHost = ref<Record<string, string | null>>({})
  const fetchSeqByHost: Record<string, number> = {}

  function disksFor(hostId: string): Disk[] {
    return disksByHost.value[hostId] ?? []
  }

  function usagesFor(hostId: string): Record<string, DiskUsage> {
    return usagesByHost.value[hostId] ?? {}
  }

  function usageFor(hostId: string, diskId: string): DiskUsage | undefined {
    return usagesFor(hostId)[diskId]
  }

  function summaryFor(hostId: string): StorageSummary | null {
    return summaryByHost.value[hostId] ?? null
  }

  function isLoading(hostId: string): boolean {
    return Boolean(loadingByHost.value[hostId])
  }

  function errorFor(hostId: string): string | null {
    return errorByHost.value[hostId] ?? null
  }

  function replaceList(hostId: string, disks: Disk[]): void {
    disksByHost.value = { ...disksByHost.value, [hostId]: disks }
  }

  function replaceOne(hostId: string, disk: Disk): void {
    const current = disksFor(hostId)
    const idx = current.findIndex((row) => row.id === disk.id)
    const next = idx >= 0 ? current.map((row, i) => (i === idx ? disk : row)) : [...current, disk]
    replaceList(hostId, next)
  }

  function replaceUsage(hostId: string, diskId: string, usage: DiskUsage): void {
    const current = usagesFor(hostId)
    usagesByHost.value = {
      ...usagesByHost.value,
      [hostId]: { ...current, [diskId]: usage },
    }
  }

  function dropUsage(hostId: string, diskId: string): void {
    const current = usagesFor(hostId)
    if (!(diskId in current)) return
    const { [diskId]: _, ...rest } = current
    usagesByHost.value = { ...usagesByHost.value, [hostId]: rest }
  }

  function invalidateFetch(hostId: string): void {
    fetchSeqByHost[hostId] = (fetchSeqByHost[hostId] ?? 0) + 1
    loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
  }

  function syncSelfList(device: HomeDeviceHealthSnapshot, disks: Disk[]): void {
    if (!isSelfDevice(device)) return
    useDiskStore().applyList(disks)
  }

  function syncSelfDisk(device: HomeDeviceHealthSnapshot, disk: Disk): void {
    if (!isSelfDevice(device)) return
    useDiskStore().applyOne(disk)
  }

  function syncSelfRemove(device: HomeDeviceHealthSnapshot, id: string): void {
    if (!isSelfDevice(device)) return
    useDiskStore().applyRemove(id)
  }

  function syncSelfUsage(device: HomeDeviceHealthSnapshot, id: string, usage: DiskUsage): void {
    if (!isSelfDevice(device)) return
    useDiskStore().applyUsage(id, usage)
  }

  function syncSelfSummary(device: HomeDeviceHealthSnapshot, next: StorageSummary): void {
    if (!isSelfDevice(device)) return
    useDiskStore().applySummary(next)
  }

  function seqIsCurrent(hostId: string, seq?: number): boolean {
    return seq == null || seq === fetchSeqByHost[hostId]
  }

  async function fetchUsages(
    device: HomeDeviceHealthSnapshot,
    ids: string[],
    seq?: number,
  ): Promise<void> {
    const hostId = device.hostId
    await Promise.all(ids.map(async (id) => {
      try {
        const { data } = await api.get<DiskUsage>(deviceDiskUsagePath(device, id))
        if (!seqIsCurrent(hostId, seq)) return
        replaceUsage(hostId, id, data)
        syncSelfUsage(device, id, data)
      } catch {
        /* keep last-known usage */
      }
    }))
  }

  async function fetchSummary(device: HomeDeviceHealthSnapshot, seq?: number): Promise<void> {
    const hostId = device.hostId
    try {
      const { data } = await api.get<StorageSummary>(deviceDiskSummaryPath(device))
      if (!seqIsCurrent(hostId, seq)) return
      summaryByHost.value = { ...summaryByHost.value, [hostId]: data }
      syncSelfSummary(device, data)
    } catch {
      /* keep last-known summary — never sum across Devices */
    }
  }

  async function fetchFor(device: HomeDeviceHealthSnapshot): Promise<void> {
    const hostId = device.hostId
    const seq = (fetchSeqByHost[hostId] ?? 0) + 1
    fetchSeqByHost[hostId] = seq
    if (!canCallDeviceAPI(device)) {
      // Keep last-known rows (PAS-47). Never invent disks on first miss.
      if (!(hostId in disksByHost.value)) {
        replaceList(hostId, [])
      }
      errorByHost.value = { ...errorByHost.value, [hostId]: null }
      loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
      return
    }
    loadingByHost.value = { ...loadingByHost.value, [hostId]: true }
    try {
      const { data } = await api.get<Disk[]>(deviceDisksPath(device))
      if (seq !== fetchSeqByHost[hostId]) return
      const disks = asDisks(data)
      replaceList(hostId, disks)
      syncSelfList(device, disks)
      errorByHost.value = { ...errorByHost.value, [hostId]: null }
      await Promise.all([
        fetchUsages(device, disks.map((row) => row.id), seq),
        fetchSummary(device, seq),
      ])
    } catch (err) {
      if (seq !== fetchSeqByHost[hostId]) return
      errorByHost.value = {
        ...errorByHost.value,
        [hostId]: apiErrorMessage(err, 'Unable to load disks'),
      }
    } finally {
      if (seq === fetchSeqByHost[hostId]) {
        loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
      }
    }
  }

  async function fetchHomeAll(devices: HomeDeviceHealthSnapshot[]): Promise<void> {
    await Promise.all(devices.map((device) => fetchFor(device)))
  }

  function homeRows(devices: HomeDeviceHealthSnapshot[]): HomeDiskRow[] {
    const rows: HomeDiskRow[] = []
    for (const device of devices) {
      const reachable = canCallDeviceAPI(device)
      const label = deviceDisplayLabel(device)
      const role = isSelfDevice(device) ? 'self' : String(device.role ?? 'member')
      for (const disk of disksFor(device.hostId)) {
        rows.push({ disk, hostId: device.hostId, label, role, reachable })
      }
    }
    return rows
  }

  function homeSummaries(devices: HomeDeviceHealthSnapshot[]): HomeDiskSummary[] {
    const rows: HomeDiskSummary[] = []
    for (const device of devices) {
      const summary = summaryFor(device.hostId)
      if (!summary) continue
      rows.push({
        hostId: device.hostId,
        label: deviceDisplayLabel(device),
        role: isSelfDevice(device) ? 'self' : String(device.role ?? 'member'),
        reachable: canCallDeviceAPI(device),
        summary,
      })
    }
    return rows
  }

  async function create(device: HomeDeviceHealthSnapshot, body: DiskWriteBody): Promise<Disk> {
    const { data } = await api.post<Disk>(deviceDisksPath(device), body)
    invalidateFetch(device.hostId)
    replaceOne(device.hostId, data)
    syncSelfDisk(device, data)
    await Promise.all([fetchUsages(device, [data.id]), fetchSummary(device)])
    return data
  }

  async function remove(device: HomeDeviceHealthSnapshot, id: string): Promise<void> {
    await api.delete(deviceDiskPath(device, id))
    invalidateFetch(device.hostId)
    replaceList(device.hostId, disksFor(device.hostId).filter((row) => row.id !== id))
    dropUsage(device.hostId, id)
    syncSelfRemove(device, id)
    await fetchSummary(device)
  }

  async function resize(device: HomeDeviceHealthSnapshot, id: string, sizeGB: number): Promise<void> {
    await api.post(deviceDiskResizePath(device, id), { sizeGB })
    await fetchFor(device)
  }

  return {
    disksByHost,
    fetchFor,
    fetchHomeAll,
    fetchSummary,
    homeRows,
    homeSummaries,
    disksFor,
    usagesFor,
    usageFor,
    summaryFor,
    isLoading,
    errorFor,
    create,
    remove,
    resize,
  }
})
