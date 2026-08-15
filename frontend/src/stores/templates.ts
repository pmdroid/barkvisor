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
import type { DeviceApiTarget } from '../utils/homeDeviceApi'
import {
  deviceTemplateDeployPath,
  deviceTemplateDryRunPath,
  deviceTemplatesPath,
  isSelfDevice,
} from '../utils/homeDeviceApi'

export type TemplateDryRunBody = { memoryMB?: number }

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

  async function fetchFor(device: DeviceApiTarget): Promise<VMTemplate[]> {
    const { data } = await api.get(deviceTemplatesPath(device))
    const rows = Array.isArray(data) ? (data as VMTemplate[]) : []
    if (isSelfDevice(device)) templates.value = rows
    return rows
  }

  async function deploy(
    req: DeployTemplateRequest,
    device?: DeviceApiTarget,
  ): Promise<DeployTemplateResponse> {
    // Never send targetHostId — member requireLocalHost stays. Route by URL.
    const { targetHostId: _ignored, ...body } = req as DeployTemplateRequest & {
      targetHostId?: string
    }
    const path = device ? deviceTemplateDeployPath(device) : '/templates/deploy'
    const { data } = await api.post<DeployTemplateResponse>(path, body)
    return data
  }

  async function dryRun(
    templateId: string,
    body: TemplateDryRunBody = {},
    device?: DeviceApiTarget,
  ): Promise<TemplateCompatibilityReport> {
    const path = device
      ? deviceTemplateDryRunPath(device, templateId)
      : `/templates/${templateId}/deploy/dry-run`
    const { data } = await api.post<TemplateCompatibilityReport>(path, {
      memoryMB: body.memoryMB,
    })
    return data
  }

  return { templates, loading, error, fetchAll, fetchFor, deploy, dryRun }
})
