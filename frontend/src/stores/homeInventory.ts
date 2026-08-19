import { ref } from 'vue'
import { apiErrorMessage } from '../api/errors'
import type { HomeDeviceHealthSnapshot } from '../api/types'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { isSelfDevice, type DeviceApiTarget } from '../utils/homeDeviceApi'

/** When a Device cannot be called, keep last-known rows (PAS-47) or drop live rows. */
export type UnreachablePolicy = 'keepLastKnown' | 'omit'

export type HomeUnionRow<T> = {
  item: T
  hostId: string
  label: string
  role: string
  reachable: boolean
}

export type HomeInventoryFetchOptions<T> = {
  device: DeviceApiTarget
  canFetch: boolean
  unreachablePolicy: UnreachablePolicy
  loadError: string
  request: () => Promise<unknown>
  asList: (data: unknown) => T[]
  /** Default true. Workload-detail logs skip the spinner when a snapshot exists. */
  setLoading?: boolean
  afterSuccess?: (ctx: {
    items: T[]
    seq: number
    seqIsCurrent: (seq?: number) => boolean
  }) => Promise<void>
}

export function asArray<T>(data: unknown): T[] {
  return Array.isArray(data) ? (data as T[]) : []
}

export function upsertById<T extends { id: string }>(list: T[], item: T): T[] {
  const idx = list.findIndex((row) => row.id === item.id)
  return idx >= 0 ? list.map((row, i) => (i === idx ? item : row)) : [...list, item]
}

export function thisDeviceTarget(
  self: DeviceApiTarget | null | undefined,
  fallbackHostId?: string | null,
): DeviceApiTarget {
  return self ?? { hostId: fallbackHostId || 'self', role: 'self' }
}

export function homeUnionRows<T>(
  devices: HomeDeviceHealthSnapshot[],
  listFor: (hostId: string) => T[],
  isReachable: (device: HomeDeviceHealthSnapshot) => boolean,
): HomeUnionRow<T>[] {
  const rows: HomeUnionRow<T>[] = []
  for (const device of devices) {
    const reachable = isReachable(device)
    const label = deviceDisplayLabel(device)
    const role = isSelfDevice(device) ? 'self' : String(device.role ?? 'member')
    for (const item of listFor(device.hostId)) {
      rows.push({ item, hostId: device.hostId, label, role, reachable })
    }
  }
  return rows
}

/**
 * One Home inventory union: data/loading/error by Device, fetchSeq, last-known (PAS-47).
 * Kind stores are thin adapters (path, normaliser, extra fetches).
 */
export function createHomeInventory<T>() {
  const dataByHost = ref<Record<string, T[]>>({})
  const loadingByHost = ref<Record<string, boolean>>({})
  const errorByHost = ref<Record<string, string | null>>({})
  const fetchSeqByHost: Record<string, number> = {}
  const selfHostId = ref<string | null>(null)

  function listFor(hostId: string): T[] {
    return dataByHost.value[hostId] ?? []
  }

  function hasList(hostId: string): boolean {
    return Object.prototype.hasOwnProperty.call(dataByHost.value, hostId)
  }

  function isLoading(hostId: string): boolean {
    return Boolean(loadingByHost.value[hostId])
  }

  function errorFor(hostId: string): string | null {
    return errorByHost.value[hostId] ?? null
  }

  function replaceList(hostId: string, items: T[]): void {
    dataByHost.value = { ...dataByHost.value, [hostId]: items }
  }

  function replaceOne(hostId: string, item: T & { id: string }): void {
    replaceList(hostId, upsertById(listFor(hostId) as Array<T & { id: string }>, item))
  }

  function removeOne(hostId: string, id: string): void {
    const current = listFor(hostId)
    if (!(current as Array<{ id?: string }>).some((row) => row.id === id)) return
    replaceList(
      hostId,
      current.filter((row) => (row as { id?: string }).id !== id),
    )
  }

  function noteSelf(device: DeviceApiTarget): void {
    if (isSelfDevice(device)) selfHostId.value = device.hostId
  }

  function nextSeq(hostId: string): number {
    const seq = (fetchSeqByHost[hostId] ?? 0) + 1
    fetchSeqByHost[hostId] = seq
    return seq
  }

  function seqIsCurrent(hostId: string, seq?: number): boolean {
    return seq == null || seq === fetchSeqByHost[hostId]
  }

  function invalidateFetch(hostId: string): void {
    fetchSeqByHost[hostId] = (fetchSeqByHost[hostId] ?? 0) + 1
    loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
  }

  function applyUnreachable(hostId: string, policy: UnreachablePolicy): void {
    if (policy === 'omit') {
      const current = dataByHost.value[hostId]
      if (!current || current.length > 0) {
        replaceList(hostId, [])
      }
    } else if (!hasList(hostId)) {
      replaceList(hostId, [])
    }
    errorByHost.value = { ...errorByHost.value, [hostId]: null }
    loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
  }

  async function fetchFor(opts: HomeInventoryFetchOptions<T>): Promise<void> {
    const hostId = opts.device.hostId
    const seq = nextSeq(hostId)
    noteSelf(opts.device)
    if (!opts.canFetch) {
      applyUnreachable(hostId, opts.unreachablePolicy)
      return
    }
    if (opts.setLoading !== false) {
      loadingByHost.value = { ...loadingByHost.value, [hostId]: true }
    }
    try {
      const data = await opts.request()
      if (!seqIsCurrent(hostId, seq)) return
      const items = opts.asList(data)
      replaceList(hostId, items)
      errorByHost.value = { ...errorByHost.value, [hostId]: null }
      if (opts.afterSuccess) {
        await opts.afterSuccess({
          items,
          seq,
          seqIsCurrent: (next = seq) => seqIsCurrent(hostId, next),
        })
      }
    } catch (err) {
      if (!seqIsCurrent(hostId, seq)) return
      errorByHost.value = {
        ...errorByHost.value,
        [hostId]: apiErrorMessage(err, opts.loadError),
      }
    } finally {
      if (seqIsCurrent(hostId, seq)) {
        loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
      }
    }
  }

  function clear(): void {
    dataByHost.value = {}
    loadingByHost.value = {}
    errorByHost.value = {}
    selfHostId.value = null
    for (const hostId of Object.keys(fetchSeqByHost)) {
      delete fetchSeqByHost[hostId]
    }
  }

  return {
    dataByHost,
    loadingByHost,
    errorByHost,
    selfHostId,
    listFor,
    hasList,
    isLoading,
    errorFor,
    replaceList,
    replaceOne,
    removeOne,
    noteSelf,
    nextSeq,
    seqIsCurrent,
    invalidateFetch,
    fetchFor,
    clear,
  }
}

export type HomeInventory<T> = ReturnType<typeof createHomeInventory<T>>
