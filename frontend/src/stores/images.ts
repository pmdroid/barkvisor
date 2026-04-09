import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import type { Image, DownloadImageRequest } from '../api/types'

export const useImageStore = defineStore('images', () => {
  const images = ref<Image[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      const { data } = await api.get('/images')
      images.value = data
    } catch (e: any) {
      error.value = e.response?.data?.reason || e.message || 'Failed to load images'
    } finally {
      loading.value = false
    }
  }

  async function startDownload(req: DownloadImageRequest): Promise<Image> {
    const { data } = await api.post('/images/download', req)
    images.value.push(data)
    return data
  }

  async function remove(id: string) {
    await api.delete(`/images/${id}`)
    images.value = images.value.filter((i) => i.id !== id)
  }

  return { images, loading, error, fetchAll, startDownload, remove }
})
