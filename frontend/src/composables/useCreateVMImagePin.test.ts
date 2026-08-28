import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { computed } from 'vue'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { Image } from '../api/types'
import { useCreateVMImagePin, imageNameFromFile, imageNameFromUrl, imageTypeFromSource } from './useCreateVMImagePin'

const originalGet = api.get
const originalPost = api.post

function readyIso(name: string): Image {
  return {
    id: 'img-win',
    name,
    imageType: 'iso',
    arch: 'arm64',
    status: 'ready',
    sizeBytes: 1,
    sourceUrl: null,
    error: null,
    sha256: null,
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
  }
}

describe('useCreateVMImagePin', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    api.get = mock((url: string) => {
      if (url === '/images' || url.endsWith('/images')) {
        return Promise.resolve({ data: [readyIso('win11')] })
      }
      return Promise.resolve({ data: [] })
    }) as typeof api.get
    api.post = mock((url: string, body?: unknown) => {
      if (url === '/images/download') {
        const req = body as { name: string; url: string; imageType: 'iso' | 'cloud-image' }
        return Promise.resolve({
          data: {
            ...readyIso(req.name),
            id: 'img-url',
            imageType: req.imageType,
            sourceUrl: req.url,
          },
        })
      }
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
  })

  test('imageTypeFromSource treats iso filenames as ISO', () => {
    expect(imageTypeFromSource('Win11.ISO')).toBe('iso')
    expect(imageTypeFromSource('debian.qcow2')).toBe('cloud-image')
  })

  test('imageNameFromFile and imageNameFromUrl strip extensions', () => {
    expect(imageNameFromFile(new File(['x'], 'Win11.iso'))).toBe('Win11')
    expect(imageNameFromUrl('https://example.test/ubuntu-24.04.qcow2')).toBe('ubuntu-24.04')
  })

  test('pinFile uses TUS metadata then selects the ready image', async () => {
    let metadata: { name: string; imageType: string; arch: string } | null = null
    const pin = useCreateVMImagePin({
      hostArch: computed(() => 'arm64'),
      startTusUpload(file, handlers) {
        metadata = handlers.metadata
        queueMicrotask(() => {
          handlers.onProgress(40, 100)
          handlers.onSuccess()
        })
        return { abort() {} }
      },
    })
    const file = new File(['iso'], 'win11.iso')
    const img = await pin.pinFile(file, 'iso')
    expect(metadata).toEqual({ name: 'win11', imageType: 'iso', arch: 'arm64' })
    expect(img.name).toBe('win11')
    expect(img.status).toBe('ready')
    expect(pin.busy.value).toBe(false)
    expect(pin.progress.value).toBe(100)
  })

  test('pinUrl posts /images/download and returns a ready image', async () => {
    const pin = useCreateVMImagePin({
      hostArch: computed(() => 'arm64'),
    })
    const img = await pin.pinUrl('https://example.test/debian.qcow2')
    expect(img.id).toBe('img-url')
    expect(img.imageType).toBe('cloud-image')
    const download = (api.post as ReturnType<typeof mock>).mock.calls.find((call) =>
      String(call[0]) === '/images/download',
    )
    expect(download).toBeTruthy()
    expect(pin.busy.value).toBe(false)
  })
})
