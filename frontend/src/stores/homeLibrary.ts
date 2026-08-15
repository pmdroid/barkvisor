import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { HomeDeviceHealthSnapshot, VMTemplate } from '../api/types'
import { canCallDeviceAPI, deviceTemplatesPath, isSelfDevice, type DeviceApiTarget } from '../utils/homeDeviceApi'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { useDevicesStore } from './devices'

export type HomeTemplateCopy = {
  hostId: string
  templateId: string
  repositoryId: string | null
}

export type HomeTemplate = VMTemplate & {
  sourceHostIds: string[]
  copies: HomeTemplateCopy[]
}

function asTemplates(data: unknown): VMTemplate[] {
  return Array.isArray(data) ? (data as VMTemplate[]) : []
}

export const useHomeLibraryStore = defineStore('homeLibrary', () => {
  const templates = ref<HomeTemplate[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  const bySlug = computed(() => {
    const map: Record<string, HomeTemplate> = {}
    for (const row of templates.value) map[row.slug] = row
    return map
  })

  function copiesOn(slug: string, hostId: string): HomeTemplateCopy | undefined {
    return bySlug.value[slug]?.copies.find((c) => c.hostId === hostId)
  }

  function deviceHasTemplate(slug: string, hostId: string): boolean {
    return Boolean(copiesOn(slug, hostId))
  }

  function templateForDevice(slug: string, hostId: string): VMTemplate | null {
    const row = bySlug.value[slug]
    if (!row) return null
    const copy = row.copies.find((c) => c.hostId === hostId)
    if (!copy) return null
    return { ...row, id: copy.templateId, repositoryId: copy.repositoryId }
  }

  /** Empty library must not imply every Device has the local catalog row. */
  function deviceHasDeployableTemplate(slug: string, device: DeviceApiTarget): boolean {
    if (templates.value.length === 0) return isSelfDevice(device)
    return deviceHasTemplate(slug, device.hostId)
  }

  /** Member IDs differ per host — never fall back to the self catalog row. */
  function resolveTemplateForDeploy(
    slug: string,
    device: DeviceApiTarget | null | undefined,
    localTemplate: VMTemplate,
  ): VMTemplate | null {
    if (!device) return localTemplate
    const fromLibrary = templateForDevice(slug, device.hostId)
    if (fromLibrary) return fromLibrary
    if (templates.value.length === 0 && isSelfDevice(device)) return localTemplate
    return null
  }

  async function fetchAll(devices?: HomeDeviceHealthSnapshot[]): Promise<void> {
    const list = devices ?? useDevicesStore().devices
    loading.value = true
    error.value = null
    try {
      const reachable = list.filter(canCallDeviceAPI)
      const targets = reachable.length > 0 ? reachable : list.filter((d) => d.role === 'self')
      const settled = await Promise.allSettled(
        (targets.length > 0
          ? targets.map(async (device) => {
              const { data } = await api.get(deviceTemplatesPath(device))
              return { device, templates: asTemplates(data) }
            })
          : [
              (async () => {
                const { data } = await api.get('/templates')
                return {
                  device: { hostId: 'self', role: 'self', reachability: 'ok', agentPort: 0 },
                  templates: asTemplates(data),
                }
              })(),
            ]),
      )
      const merged = new Map<string, HomeTemplate>()
      for (const result of settled) {
        if (result.status !== 'fulfilled') continue
        const { device, templates: rows } = result.value
        for (const tpl of rows) {
          const existing = merged.get(tpl.slug)
          const copy: HomeTemplateCopy = {
            hostId: device.hostId,
            templateId: tpl.id,
            repositoryId: tpl.repositoryId,
          }
          if (!existing) {
            merged.set(tpl.slug, {
              ...tpl,
              sourceHostIds: [device.hostId],
              copies: [copy],
            })
            continue
          }
          if (!existing.sourceHostIds.includes(device.hostId)) {
            existing.sourceHostIds.push(device.hostId)
            existing.copies.push(copy)
          }
        }
      }
      const rejected = settled.filter((r) => r.status === 'rejected')
      if (merged.size === 0 && rejected.length > 0) {
        const first = rejected[0]
        error.value = first.status === 'rejected'
          ? apiErrorMessage(first.reason, 'Failed to load templates')
          : 'Failed to load templates'
      }
      templates.value = [...merged.values()].sort((a, b) => a.name.localeCompare(b.name))
    } catch (e: unknown) {
      error.value = apiErrorMessage(e, 'Failed to load templates')
    } finally {
      loading.value = false
    }
  }

  function sourceLine(row: HomeTemplate, labelFor: (hostId: string) => string = (id) => id): string {
    return row.sourceHostIds.map(labelFor).join(', ')
  }

  function defaultLabelFor(hostId: string): string {
    const devices = useDevicesStore()
    const row = devices.deviceByHostId(hostId)
    return row ? deviceDisplayLabel(row) : hostId
  }

  return {
    templates,
    loading,
    error,
    bySlug,
    copiesOn,
    deviceHasTemplate,
    templateForDevice,
    deviceHasDeployableTemplate,
    resolveTemplateForDeploy,
    fetchAll,
    sourceLine,
    defaultLabelFor,
  }
})
