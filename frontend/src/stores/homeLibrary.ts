import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { HomeDeviceHealthSnapshot, Image, VMTemplate } from '../api/types'
import {
  canCallDeviceAPI,
  devicePath,
  deviceTemplatesPath,
  isSelfDevice,
  type DeviceApiTarget,
} from '../utils/homeDeviceApi'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { useDevicesStore } from './devices'

export type HomeImageCopy = {
  hostId: string
  imageId: string
  status: Image['status']
}

export type HomeImage = Image & {
  libraryKey: string
  sourceHostIds: string[]
  copies: HomeImageCopy[]
}

/**
 * Stable Home Library identity.
 * Checksum when present; else size+sourceUrl when both exist; else id-scoped
 * so two different ISOs with the same type/arch/name never collapse.
 */
export function homeImageKey(
  img: Pick<Image, 'id' | 'name' | 'imageType' | 'arch' | 'sha256' | 'sizeBytes' | 'sourceUrl'>,
): string {
  const sha = img.sha256?.trim()
  if (sha) return `sha256:${sha}`
  const size = img.sizeBytes
  const src = img.sourceUrl?.trim() ?? ''
  if (size != null && src) {
    return `${img.imageType}:${img.arch}:${img.name}:${size}:${src}`
  }
  return `id:${img.id}`
}

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

function asImages(data: unknown): Image[] {
  return Array.isArray(data) ? (data as Image[]) : []
}

function readySourceHostIds(copies: HomeImageCopy[]): string[] {
  return copies.filter((c) => c.status === 'ready').map((c) => c.hostId)
}

function upsertHomeImage(merged: Map<string, HomeImage>, hostId: string, img: Image): void {
  const key = homeImageKey(img)
  const copy: HomeImageCopy = { hostId, imageId: img.id, status: img.status }
  const existing = merged.get(key)
  if (!existing) {
    merged.set(key, {
      ...img,
      libraryKey: key,
      sourceHostIds: img.status === 'ready' ? [hostId] : [],
      copies: [copy],
    })
    return
  }
  if (img.status === 'ready' && existing.status !== 'ready') {
    Object.assign(existing, {
      ...img,
      libraryKey: key,
      sourceHostIds: existing.sourceHostIds,
      copies: existing.copies,
    })
  }
  const prev = existing.copies.find((c) => c.hostId === hostId)
  if (!prev) {
    existing.copies.push(copy)
  } else {
    prev.imageId = img.id
    prev.status = img.status
  }
  existing.sourceHostIds = readySourceHostIds(existing.copies)
}

function restoreLastGoodImages(
  merged: Map<string, HomeImage>,
  previous: HomeImage[],
  successfulHostIds: Set<string>,
): void {
  for (const prev of previous) {
    const leftover = prev.copies.filter((c) => !successfulHostIds.has(c.hostId))
    if (leftover.length === 0) continue
    const existing = merged.get(prev.libraryKey)
    if (!existing) {
      merged.set(prev.libraryKey, {
        ...prev,
        copies: leftover,
        sourceHostIds: readySourceHostIds(leftover),
      })
      continue
    }
    for (const copy of leftover) {
      if (existing.copies.some((c) => c.hostId === copy.hostId)) continue
      existing.copies.push(copy)
    }
    if (existing.status !== 'ready' && leftover.some((c) => c.status === 'ready')) {
      Object.assign(existing, {
        ...prev,
        libraryKey: existing.libraryKey,
        copies: existing.copies,
        sourceHostIds: existing.sourceHostIds,
      })
    }
    existing.sourceHostIds = readySourceHostIds(existing.copies)
  }
}

export const useHomeLibraryStore = defineStore('homeLibrary', () => {
  const templates = ref<HomeTemplate[]>([])
  const images = ref<HomeImage[]>([])
  const loading = ref(false)
  const imagesLoading = ref(false)
  const error = ref<string | null>(null)
  const imagesError = ref<string | null>(null)

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
  function imageByKey(key: string): HomeImage | undefined {
    return images.value.find((row) => row.libraryKey === key)
  }

  function deviceHasImage(key: string, hostId: string): boolean {
    return Boolean(imageByKey(key)?.copies.some((c) => c.hostId === hostId && c.status === 'ready'))
  }

  function imageForDevice(key: string, hostId: string): Image | null {
    const row = imageByKey(key)
    if (!row) return null
    const copy = row.copies.find((c) => c.hostId === hostId && c.status === 'ready')
    if (!copy) return null
    return { ...row, id: copy.imageId, status: copy.status }
  }

  /** Empty library must not imply every Device has a local copy. */
  function deviceHasLibraryImage(key: string, device: DeviceApiTarget): boolean {
    if (images.value.length === 0) return isSelfDevice(device)
    return deviceHasImage(key, device.hostId)
  }

  function resolveImageForCreate(
    key: string,
    device: DeviceApiTarget | null | undefined,
    fallback: Image | null,
  ): Image | null {
    if (!device) return fallback
    const fromLibrary = imageForDevice(key, device.hostId)
    if (fromLibrary) return fromLibrary
    if (images.value.length === 0 && isSelfDevice(device)) return fallback
    return null
  }

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
      const successfulHostIds = new Set<string>()
      for (const result of settled) {
        if (result.status !== 'fulfilled') continue
        const { device, templates: rows } = result.value
        successfulHostIds.add(device.hostId)
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
          if (!existing.copies.some((c) => c.hostId === device.hostId)) {
            existing.sourceHostIds.push(device.hostId)
            existing.copies.push(copy)
          }
        }
      }
      const rejected = settled.filter((r) => r.status === 'rejected')
      if (rejected.length > 0) {
        for (const prev of templates.value) {
          const leftover = prev.copies.filter((c) => !successfulHostIds.has(c.hostId))
          if (leftover.length === 0) continue
          const existing = merged.get(prev.slug)
          if (!existing) {
            merged.set(prev.slug, {
              ...prev,
              sourceHostIds: leftover.map((c) => c.hostId),
              copies: leftover,
            })
            continue
          }
          for (const copy of leftover) {
            if (existing.copies.some((c) => c.hostId === copy.hostId)) continue
            existing.sourceHostIds.push(copy.hostId)
            existing.copies.push(copy)
          }
        }
      }
      if (merged.size === 0 && rejected.length > 0) {
        const first = rejected[0]
        error.value = first.status === 'rejected'
          ? apiErrorMessage(first.reason, 'Failed to load templates')
          : 'Failed to load templates'
      }
      if (successfulHostIds.size === 0 && rejected.length > 0 && templates.value.length > 0) {
        error.value = error.value ?? 'Failed to refresh templates'
      } else {
        templates.value = [...merged.values()].sort((a, b) => a.name.localeCompare(b.name))
      }
    } catch (e: unknown) {
      error.value = apiErrorMessage(e, 'Failed to load templates')
    } finally {
      loading.value = false
    }
  }

  async function fetchImages(devices?: HomeDeviceHealthSnapshot[]): Promise<void> {
    const list = devices ?? useDevicesStore().devices
    imagesLoading.value = true
    imagesError.value = null
    try {
      const reachable = list.filter(canCallDeviceAPI)
      const targets = reachable.length > 0 ? reachable : list.filter((d) => d.role === 'self')
      const settled = await Promise.allSettled(
        (targets.length > 0
          ? targets.map(async (device) => {
              const { data } = await api.get(devicePath(device, '/images'))
              return { device, images: asImages(data) }
            })
          : [
              (async () => {
                const { data } = await api.get('/images')
                return {
                  device: { hostId: 'self', role: 'self', reachability: 'ok', agentPort: 0 },
                  images: asImages(data),
                }
              })(),
            ]),
      )
      const merged = new Map<string, HomeImage>()
      const successfulHostIds = new Set<string>()
      for (const result of settled) {
        if (result.status !== 'fulfilled') continue
        const { device, images: rows } = result.value
        successfulHostIds.add(device.hostId)
        for (const img of rows) {
          upsertHomeImage(merged, device.hostId, img)
        }
      }
      const rejected = settled.filter((r) => r.status === 'rejected')
      if (rejected.length > 0) {
        restoreLastGoodImages(merged, images.value, successfulHostIds)
      }
      if (merged.size === 0 && rejected.length > 0) {
        const first = rejected[0]
        imagesError.value = first.status === 'rejected'
          ? apiErrorMessage(first.reason, 'Failed to load images')
          : 'Failed to load images'
      }
      if (successfulHostIds.size === 0 && rejected.length > 0 && images.value.length > 0) {
        imagesError.value = imagesError.value ?? 'Failed to refresh images'
      } else {
        images.value = [...merged.values()].sort((a, b) => a.name.localeCompare(b.name))
      }
    } catch (e: unknown) {
      imagesError.value = apiErrorMessage(e, 'Failed to load images')
    } finally {
      imagesLoading.value = false
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
    images,
    loading,
    imagesLoading,
    error,
    imagesError,
    bySlug,
    copiesOn,
    deviceHasTemplate,
    templateForDevice,
    deviceHasDeployableTemplate,
    resolveTemplateForDeploy,
    imageByKey,
    deviceHasImage,
    imageForDevice,
    deviceHasLibraryImage,
    resolveImageForCreate,
    fetchAll,
    fetchImages,
    sourceLine,
    defaultLabelFor,
  }
})
