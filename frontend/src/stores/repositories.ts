import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import type { ImageRepository, RepositoryImage } from '../api/types'
import { useTaskPoller } from '../composables/useTaskPoller'

export const useRepositoryStore = defineStore('repositories', () => {
  const repositories = ref<ImageRepository[]>([])
  const imagesByRepo = ref<Record<string, RepositoryImage[]>>({})
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      const { data } = await api.get('/repositories')
      repositories.value = data
    } catch (e: any) {
      error.value = e.response?.data?.reason || e.message || 'Failed to load repositories'
    } finally {
      loading.value = false
    }
  }

  async function add(url: string, repoType: 'images' | 'templates'): Promise<ImageRepository> {
    const { data } = await api.post('/repositories', { url, repoType })
    repositories.value.push(data)
    return data
  }

  async function remove(id: string) {
    await api.delete(`/repositories/${id}`)
    repositories.value = repositories.value.filter(r => r.id !== id)
    delete imagesByRepo.value[id]
  }

  const activeSyncPollers = new Map<string, () => void>()

  async function sync(id: string): Promise<void> {
    const res = await api.post(`/repositories/${id}/sync`)

    // Mark as syncing locally
    const idx = repositories.value.findIndex(r => r.id === id)
    if (idx >= 0) repositories.value[idx] = { ...repositories.value[idx], syncStatus: 'syncing' }

    if (res.status === 202 && res.data.taskID) {
      // Cancel any existing poller for this repo
      activeSyncPollers.get(id)?.()

      const { poll, stop } = useTaskPoller()
      activeSyncPollers.set(id, stop)

      try {
        await poll(res.data.taskID, {
          onComplete: () => { fetchAll() },
          onFailed: (event) => {
            const current = repositories.value.findIndex(r => r.id === id)
            if (current >= 0) {
              repositories.value[current] = { ...repositories.value[current], syncStatus: 'error', lastError: event.error ?? null }
            }
          },
        })
      } finally {
        activeSyncPollers.delete(id)
      }
    }
  }

  async function fetchImages(id: string): Promise<RepositoryImage[]> {
    const { data } = await api.get(`/repositories/${id}/images`)
    imagesByRepo.value[id] = data
    return data
  }

  async function downloadImage(repoImageId: string) {
    await api.post(`/repositories/images/${repoImageId}/download`)
  }

  return { repositories, imagesByRepo, loading, error, fetchAll, add, remove, sync, fetchImages, downloadImage }
})
