import { ref, type ComputedRef } from 'vue'
import * as tus from 'tus-js-client'
import api from '../api/client'
import type { Image, ImageArch } from '../api/types'
import { apiErrorMessage } from '../api/errors'
import { resolveImageArch } from '../utils/imageArch'
import { imageProgressPercent } from '../utils/imageProgress'
import { useImageStore } from '../stores/images'
import { useHomeLibraryStore } from '../stores/homeLibrary'
import { useDevicesStore } from '../stores/devices'
import { useImageProgress } from './useTicketedEventSource'

export type ImagePinTusSession = {
  abort: () => void
}

export type ImagePinTusHandlers = {
  metadata: { name: string; imageType: string; arch: string }
  headers: Record<string, string>
  onProgress: (bytesUploaded: number, bytesTotal: number) => void
  onError: (error: { message?: string }) => void
  onSuccess: () => void
}

export function imageTypeFromSource(source: string): 'iso' | 'cloud-image' {
  return source.toLowerCase().includes('.iso') ? 'iso' : 'cloud-image'
}

export function imageNameFromFile(file: File): string {
  return file.name.replace(/\.\w+$/, '')
}

export function imageNameFromUrl(url: string): string {
  try {
    const path = new URL(url).pathname
    const base = path.split('/').pop() || ''
    if (base) return base.replace(/\.(iso|img|qcow2|raw|vmdk)(\.(xz|gz|bz2|zst))?$/i, '')
  } catch {
    const base = url.split('/').pop() || ''
    if (base) return base.replace(/\.(iso|img|qcow2|raw|vmdk)(\.(xz|gz|bz2|zst))?$/i, '')
  }
  return 'image'
}

function defaultStartTus(file: File, handlers: ImagePinTusHandlers): ImagePinTusSession {
  const token = typeof localStorage === 'undefined' ? null : localStorage.getItem('token')
  const upload = new tus.Upload(file, {
    endpoint: '/api/images/tus',
    retryDelays: [0, 1000, 3000, 5000],
    chunkSize: 5 * 1024 * 1024,
    metadata: handlers.metadata,
    headers: token ? { Authorization: `Bearer ${token}` } : handlers.headers,
    onError(error: Error) {
      handlers.onError(error)
    },
    onProgress(bytesUploaded: number, bytesTotal: number) {
      handlers.onProgress(bytesUploaded, bytesTotal)
    },
    onSuccess() {
      handlers.onSuccess()
    },
  })
  upload.start()
  return {
    abort() {
      upload.abort()
    },
  }
}

export function useCreateVMImagePin(opts: {
  hostArch: ComputedRef<string | null | undefined>
  startTusUpload?: (file: File, handlers: ImagePinTusHandlers) => ImagePinTusSession
}) {
  const imageStore = useImageStore()
  const homeLibrary = useHomeLibraryStore()
  const devicesStore = useDevicesStore()
  const urlProgress = useImageProgress()

  const busy = ref(false)
  const progress = ref<number | null>(null)
  const error = ref('')
  const status = ref('')
  let tusSession: ImagePinTusSession | null = null

  function abort() {
    tusSession?.abort()
    tusSession = null
    urlProgress.stop()
    busy.value = false
  }

  function archFor(source: string): ImageArch {
    return resolveImageArch(source, opts.hostArch.value)
  }

  async function findReadyImage(name: string, id?: string): Promise<Image | null> {
    await imageStore.fetchAll()
    await homeLibrary.fetchImages(devicesStore.devices).catch(() => {})
    const fromStore = imageStore.images.find((row) =>
      row.status === 'ready' && (id ? row.id === id : row.name === name),
    )
    if (fromStore) return fromStore
    const fromLibrary = homeLibrary.images.find((row) =>
      row.status === 'ready' && (id ? row.id === id : row.name === name),
    )
    return fromLibrary ?? null
  }

  function pinFile(file: File, imageType?: 'iso' | 'cloud-image'): Promise<Image> {
    error.value = ''
    abort()
    busy.value = true
    progress.value = 0
    status.value = 'uploading'
    const name = imageNameFromFile(file)
    const type = imageType ?? imageTypeFromSource(file.name)
    const startTus = opts.startTusUpload ?? defaultStartTus
    const token = typeof localStorage === 'undefined' ? null : localStorage.getItem('token')
    return new Promise((resolve, reject) => {
      tusSession = startTus(file, {
        metadata: {
          name,
          imageType: type,
          arch: archFor(file.name),
        },
        headers: token ? { Authorization: `Bearer ${token}` } : {},
        onProgress(bytesUploaded, bytesTotal) {
          if (bytesTotal > 0) progress.value = Math.round((bytesUploaded / bytesTotal) * 100)
        },
        onError(err) {
          busy.value = false
          error.value = err.message || 'Upload failed'
          status.value = 'error'
          reject(new Error(error.value))
        },
        onSuccess() {
          void findReadyImage(name).then((img) => {
            busy.value = false
            if (!img) {
              error.value = 'Upload finished but the image is not ready yet'
              status.value = 'error'
              reject(new Error(error.value))
              return
            }
            progress.value = 100
            status.value = 'ready'
            resolve(img)
          }).catch((e) => {
            busy.value = false
            error.value = apiErrorMessage(e)
            status.value = 'error'
            reject(e)
          })
        },
      })
    })
  }

  async function pinUrl(url: string, imageType?: 'iso' | 'cloud-image'): Promise<Image> {
    const source = url.trim()
    if (!source) {
      error.value = 'URL required'
      throw new Error(error.value)
    }
    error.value = ''
    abort()
    busy.value = true
    progress.value = null
    status.value = 'downloading'
    try {
      const type = imageType ?? imageTypeFromSource(source)
      const name = imageNameFromUrl(source)
      const { data } = await api.post('/images/download', {
        name,
        url: source,
        imageType: type,
        arch: archFor(source),
      })
      const started = data as Image
      imageStore.images.push(started)
      if (started.status === 'ready') {
        busy.value = false
        progress.value = 100
        status.value = 'ready'
        return started
      }
      return await new Promise((resolve, reject) => {
        urlProgress.start(started.id, {
          onProgress(msg) {
            progress.value = imageProgressPercent(msg)
            status.value = msg.status ?? 'downloading'
          },
          onReady() {
            void findReadyImage(name, started.id).then((img) => {
              busy.value = false
              progress.value = 100
              status.value = 'ready'
              if (img) {
                resolve(img)
                return
              }
              started.status = 'ready'
              resolve(started)
            })
          },
          onError(msg) {
            busy.value = false
            error.value = msg?.error || 'Download failed'
            status.value = 'error'
            reject(new Error(error.value))
          },
        })
      })
    } catch (e: unknown) {
      busy.value = false
      error.value = apiErrorMessage(e)
      status.value = 'error'
      throw e
    }
  }

  return {
    busy,
    progress,
    error,
    status,
    abort,
    pinFile,
    pinUrl,
  }
}
