import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import type { VMTemplate, DeployTemplateRequest, DeployTemplateResponse } from '../api/types'

export const useTemplateStore = defineStore('templates', () => {
  const templates = ref<VMTemplate[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      const { data } = await api.get('/templates')
      templates.value = data
    } catch (e: any) {
      error.value = e.response?.data?.reason || e.message || 'Failed to load templates'
    } finally {
      loading.value = false
    }
  }

  async function deploy(req: DeployTemplateRequest): Promise<DeployTemplateResponse> {
    const { data } = await api.post('/templates/deploy', req)
    return data
  }

  return { templates, loading, error, fetchAll, deploy }
})
