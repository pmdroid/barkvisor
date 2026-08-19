import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
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
  type DeviceApiTarget,
} from '../utils/homeDeviceApi'
import { asArray, createHomeInventory, homeUnionRows } from './homeInventory'

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

export const useDeviceDisksStore = defineStore('deviceDisks', () => {
  const inventory = createHomeInventory<Disk>()
  const usagesByHost = ref<Record<string, Record<string, DiskUsage>>>({})
  const summaryByHost = ref<Record<string, StorageSummary>>({})

  function disksFor(hostId: string): Disk[] {
    return inventory.listFor(hostId)
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

  function applySummary(hostId: string, next: StorageSummary): void {
    summaryByHost.value = { ...summaryByHost.value, [hostId]: next }
  }

  async function fetchUsages(
    device: DeviceApiTarget,
    ids: string[],
    seq?: number,
  ): Promise<void> {
    const hostId = device.hostId
    await Promise.all(ids.map(async (id) => {
      try {
        const { data } = await api.get<DiskUsage>(deviceDiskUsagePath(device, id))
        if (!inventory.seqIsCurrent(hostId, seq)) return
        replaceUsage(hostId, id, data)
      } catch {
        /* keep last-known usage */
      }
    }))
  }

  async function fetchSummary(device: DeviceApiTarget, seq?: number): Promise<void> {
    const hostId = device.hostId
    try {
      const { data } = await api.get<StorageSummary>(deviceDiskSummaryPath(device))
      if (!inventory.seqIsCurrent(hostId, seq)) return
      applySummary(hostId, data)
    } catch {
      /* keep last-known summary — never sum across Devices */
    }
  }

  async function fetchFor(
    device: DeviceApiTarget,
    extras: { usages?: boolean; summary?: boolean } = { usages: true, summary: true },
  ): Promise<void> {
    await inventory.fetchFor({
      device,
      canFetch: canCallDeviceAPI(device),
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load disks',
      request: async () => {
        const { data } = await api.get<Disk[]>(deviceDisksPath(device))
        return data
      },
      asList: asArray<Disk>,
      afterSuccess: async ({ items, seq }) => {
        const tasks: Promise<void>[] = []
        if (extras.usages !== false) {
          tasks.push(fetchUsages(device, items.map((row) => row.id), seq))
        }
        if (extras.summary !== false) {
          tasks.push(fetchSummary(device, seq))
        }
        await Promise.all(tasks)
      },
    })
  }

  async function fetchHomeAll(devices: HomeDeviceHealthSnapshot[]): Promise<void> {
    await Promise.all(devices.map((device) => fetchFor(device)))
  }

  function homeRows(devices: HomeDeviceHealthSnapshot[]): HomeDiskRow[] {
    return homeUnionRows(devices, disksFor, canCallDeviceAPI).map((row) => ({
      disk: row.item,
      hostId: row.hostId,
      label: row.label,
      role: row.role,
      reachable: row.reachable,
    }))
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

  async function create(device: DeviceApiTarget, body: DiskWriteBody): Promise<Disk> {
    const { data } = await api.post<Disk>(deviceDisksPath(device), body)
    inventory.invalidateFetch(device.hostId)
    inventory.noteSelf(device)
    inventory.replaceOne(device.hostId, data)
    await Promise.all([fetchUsages(device, [data.id]), fetchSummary(device)])
    return data
  }

  async function remove(device: DeviceApiTarget, id: string): Promise<void> {
    await api.delete(deviceDiskPath(device, id))
    inventory.invalidateFetch(device.hostId)
    inventory.noteSelf(device)
    inventory.replaceList(device.hostId, disksFor(device.hostId).filter((row) => row.id !== id))
    dropUsage(device.hostId, id)
    await fetchSummary(device)
  }

  async function resize(device: DeviceApiTarget, id: string, sizeGB: number): Promise<void> {
    await api.post(deviceDiskResizePath(device, id), { sizeGB })
    await fetchFor(device)
  }

  return {
    disksByHost: inventory.dataByHost,
    selfHostId: inventory.selfHostId,
    fetchFor,
    fetchHomeAll,
    fetchSummary,
    fetchUsages,
    homeRows,
    homeSummaries,
    disksFor,
    usagesFor,
    usageFor,
    summaryFor,
    isLoading: inventory.isLoading,
    errorFor: inventory.errorFor,
    create,
    remove,
    resize,
    replaceList: inventory.replaceList,
    replaceOne: inventory.replaceOne,
    replaceUsage,
    dropUsage,
    applySummary,
    noteSelf: inventory.noteSelf,
    invalidateFetch: inventory.invalidateFetch,
  }
})
