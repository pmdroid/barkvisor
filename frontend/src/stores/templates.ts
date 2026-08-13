import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import type {
  VMTemplate,
  DeployTemplateRequest,
  DeployTemplateResponse,
  TemplateCompatibilityReport,
} from '../api/types'
import { apiErrorMessage } from '../api/errors'

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
      error.value = apiErrorMessage(e, 'Failed to load templates')
    } finally {
      loading.value = false
    }
  }

  async function deploy(req: DeployTemplateRequest): Promise<DeployTemplateResponse> {
    // 200 (created/downloading) or 202 (provisioning) — both return the same body shape.
    const { data } = await api.post<DeployTemplateResponse>('/templates/deploy', req)
    return data
  }

  async function dryRun(
    templateId: string,
    body: { targetHostId?: string; memoryMB?: number } = {},
  ): Promise<TemplateCompatibilityReport> {
    const { data } = await api.post<TemplateCompatibilityReport>(
      `/templates/${templateId}/deploy/dry-run`,
      body,
    )
    return data
  }

  return { templates, loading, error, fetchAll, deploy, dryRun }
})
