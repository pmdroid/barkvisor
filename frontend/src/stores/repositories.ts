import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot, RepositoryImage } from '../api/types'
import { apiErrorMessage } from '../api/errors'
import { useTaskPoller } from '../composables/useTaskPoller'
import {
  canCallDeviceAPI,
  deviceRepositoriesPath,
  deviceRepositorySyncPath,
  deviceTaskPath,
  isSelfDevice,
  type DeviceApiTarget,
} from '../utils/homeDeviceApi'
import {
  asRepositories,
  attachDeviceSyncs,
  type CatalogMemberFetch,
  type HomeCatalogRepository,
} from '../utils/repositoryCatalog'
import { useDevicesStore } from './devices'

export const useRepositoryStore = defineStore('repositories', () => {
  const repositories = ref<HomeCatalogRepository[]>([])
  const imagesByRepo = ref<Record<string, RepositoryImage[]>>({})
  const loading = ref(false)
  const error = ref<string | null>(null)
  let rememberedDevices: HomeDeviceHealthSnapshot[] = []

  async function fetchAll(devices?: HomeDeviceHealthSnapshot[]) {
    loading.value = true
    error.value = null
    try {
      const fromStore = useDevicesStore().devices
      const list = devices ?? (fromStore.length > 0 ? fromStore : rememberedDevices)
      if (list.length > 0) rememberedDevices = list
      const { data } = await api.get('/repositories')
      const homeRepos = asRepositories(data)
      const self = list.find((row) => isSelfDevice(row)) ?? null
      const members = list.filter((row) => !isSelfDevice(row))
      const memberResults: CatalogMemberFetch[] = await Promise.all(
        members.map(async (device) => {
          if (!canCallDeviceAPI(device)) {
            return { device, reachable: false }
          }
          try {
            const res = await api.get(deviceRepositoriesPath(device))
            return { device, reachable: true, repos: asRepositories(res.data) }
          } catch (e: unknown) {
            return {
              device,
              reachable: true,
              error: apiErrorMessage(e, 'Failed to load repositories'),
            }
          }
        }),
      )
      repositories.value = attachDeviceSyncs(homeRepos, self, memberResults)
    } catch (e: unknown) {
      error.value = apiErrorMessage(e, 'Failed to load repositories')
    } finally {
      loading.value = false
    }
  }

  async function add(url: string, repoType: 'images' | 'templates'): Promise<HomeCatalogRepository> {
    const { data } = await api.post('/repositories', { url, repoType })
    await fetchAll()
    return repositories.value.find((row) => row.id === data.id) ?? { ...data, deviceSyncs: [] }
  }

  async function remove(id: string) {
    await api.delete(`/repositories/${id}`)
    repositories.value = repositories.value.filter((r) => r.id !== id)
    delete imagesByRepo.value[id]
  }

  const activeSyncPollers = new Map<string, () => void>()

  function setDeviceSyncing(homeId: string, hostId: string) {
    const idx = repositories.value.findIndex((r) => r.id === homeId)
    if (idx < 0) return
    const current = repositories.value[idx]
    repositories.value[idx] = {
      ...current,
      syncStatus: 'syncing',
      deviceSyncs: current.deviceSyncs.map((row) =>
        row.hostId === hostId ? { ...row, syncStatus: 'syncing', lastError: null } : row,
      ),
    }
  }

  function setDeviceSyncError(homeId: string, hostId: string, lastError: string | null) {
    const idx = repositories.value.findIndex((r) => r.id === homeId)
    if (idx < 0) return
    const current = repositories.value[idx]
    const deviceSyncs = current.deviceSyncs.map((row) =>
      row.hostId === hostId ? { ...row, syncStatus: 'error', lastError } : row,
    )
    repositories.value[idx] = {
      ...current,
      syncStatus: 'error',
      lastError: lastError ?? current.lastError,
      deviceSyncs,
    }
  }

  async function syncOnDevice(
    homeId: string,
    device: DeviceApiTarget,
    repoId: string,
  ): Promise<void> {
    const res = await api.post(deviceRepositorySyncPath(device, repoId))
    setDeviceSyncing(homeId, device.hostId)

    if (res.status === 202 && res.data?.taskID) {
      const key = `${device.hostId}:${repoId}`
      activeSyncPollers.get(key)?.()

      const { poll, stop } = useTaskPoller()
      activeSyncPollers.set(key, stop)

      try {
        await poll(res.data.taskID, {
          path: deviceTaskPath(device, res.data.taskID),
          onFailed: (event) => {
            setDeviceSyncError(homeId, device.hostId, event.error ?? null)
          },
        })
      } finally {
        activeSyncPollers.delete(key)
      }
    }
  }

  async function sync(id: string): Promise<void> {
    const repo = repositories.value.find((r) => r.id === id)
    const targets = (repo?.deviceSyncs ?? [])
      .filter((row) => row.repoId && row.reachable)
      .map((row) => ({
        hostId: row.hostId,
        role: row.role,
        reachability: 'ok' as const,
        repoId: row.repoId as string,
      }))

    if (targets.length === 0) {
      await syncOnDevice(id, { hostId: 'self', role: 'self', reachability: 'ok' }, id)
      await fetchAll()
      return
    }

    const settled = await Promise.allSettled(
      targets.map((target) =>
        syncOnDevice(id, target, target.repoId),
      ),
    )
    await fetchAll()
    const failed = settled.find((row) => row.status === 'rejected')
    if (failed && failed.status === 'rejected') throw failed.reason
  }

  async function fetchImages(id: string): Promise<RepositoryImage[]> {
    const { data } = await api.get(`/repositories/${id}/images`)
    imagesByRepo.value[id] = data
    return data
  }

  async function downloadImage(repoImageId: string) {
    await api.post(`/repositories/images/${repoImageId}/download`)
  }

  return {
    repositories,
    imagesByRepo,
    loading,
    error,
    fetchAll,
    add,
    remove,
    sync,
    fetchImages,
    downloadImage,
  }
})
