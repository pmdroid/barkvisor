import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { computed, ref } from 'vue'
import api from '../api/client'
import { useVirtioDownload } from './useVirtioDownload'

const originalGet = api.get
const originalPost = api.post

describe('useVirtioDownload (PAS-240)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    api.get = mock(() => Promise.resolve({ data: { available: false } })) as typeof api.get
    api.post = mock(() => Promise.resolve({ data: {} })) as typeof api.post
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
  })

  test('checkVirtioWinStatus follows the picked Device path', async () => {
    const get = mock((url: string) => {
      if (url === '/home/devices/studio/v1/system/virtio-win/status') {
        return Promise.resolve({ data: { available: true, imageId: 'virtio-1' } })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get
    const virtio = useVirtioDownload({
      selectedHostId: ref('studio'),
      selectedDevice: computed(() => ({ hostId: 'studio', role: 'member' })),
      osType: ref('windows'),
    })
    await virtio.checkVirtioWinStatus()
    expect(virtio.virtioWinAvailable.value).toBe(true)
    expect(virtio.virtioWinImageId.value).toBe('virtio-1')
  })

  test('missing Device marks VirtIO unavailable and refuses download', async () => {
    const virtio = useVirtioDownload({
      selectedHostId: ref('ghost'),
      selectedDevice: computed(() => null),
      osType: ref('windows'),
    })
    await virtio.checkVirtioWinStatus()
    expect(virtio.virtioWinAvailable.value).toBe(false)
    await virtio.startVirtioWinDownload()
    expect(virtio.virtioWinDownloading.value).toBe(false)
    expect(virtio.virtioWinError.value).toBe('The selected Device is no longer available. Pick a Device again.')
  })

  test('member download polls the Device task until completed', async () => {
    const post = mock((url: string) => {
      if (url === '/home/devices/studio/v1/system/virtio-win/download') {
        return Promise.resolve({ data: { imageId: 'virtio-2', taskID: 't-virtio' } })
      }
      throw new Error(`unexpected POST ${url}`)
    })
    const get = mock((url: string) => {
      if (url === '/home/devices/studio/v1/tasks/t-virtio') {
        return Promise.resolve({
          data: {
            taskID: 't-virtio',
            kind: 'imageDownload',
            status: 'completed',
            progress: 100,
            error: null,
            resultPayload: null,
          },
        })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.post = post as typeof api.post
    api.get = get as typeof api.get

    const virtio = useVirtioDownload({
      selectedHostId: ref('studio'),
      selectedDevice: computed(() => ({ hostId: 'studio', role: 'member' })),
      osType: ref('windows'),
    })
    await virtio.startVirtioWinDownload()
    expect(virtio.virtioWinAvailable.value).toBe(true)
    expect(virtio.virtioWinDownloading.value).toBe(false)
    expect(virtio.virtioWinImageId.value).toBe('virtio-2')
    expect(virtio.virtioWinError.value).toBe('')
  })

  test('member download without a task id tells the operator to refresh', async () => {
    api.post = mock(() => Promise.resolve({ data: { imageId: 'virtio-3' } })) as typeof api.post
    const virtio = useVirtioDownload({
      selectedHostId: ref('studio'),
      selectedDevice: computed(() => ({ hostId: 'studio', role: 'member' })),
      osType: ref('windows'),
    })
    await virtio.startVirtioWinDownload()
    expect(virtio.virtioWinAvailable.value).toBe(false)
    expect(virtio.virtioWinError.value).toBe('Download started on the Device. Refresh this step shortly.')
  })
})
