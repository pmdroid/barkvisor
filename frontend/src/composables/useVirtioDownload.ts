import { ref, watch, type ComputedRef, type Ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import { useImageStore } from '../stores/images'
import {
  devicePath,
  deviceTaskPath,
  isSelfDevice,
  type DeviceApiTarget,
} from '../utils/homeDeviceApi'
import { imageProgressPercent } from '../utils/imageProgress'
import { useImageProgress } from './useTicketedEventSource'
import { useTaskPoller } from './useTaskPoller'

export function useVirtioDownload(opts: {
  selectedHostId: Ref<string>
  selectedDevice: ComputedRef<DeviceApiTarget | null | undefined>
  osType: Ref<'linux' | 'windows'>
}) {
  const imageStore = useImageStore()

  const virtioWinAvailable = ref(false)
  const virtioWinImageId = ref<string | null>(null)
  const virtioWinDownloading = ref(false)
  const virtioWinProgress = ref(0)
  const virtioWinStatus = ref<string>('')
  const virtioWinError = ref('')

  let virtioCheckSeq = 0
  const virtioProgress = useImageProgress()

  async function checkVirtioWinStatus() {
    const seq = ++virtioCheckSeq
    try {
      const target = opts.selectedDevice.value
      if (opts.selectedHostId.value && !target) {
        if (seq === virtioCheckSeq) virtioWinAvailable.value = false
        return
      }
      const path = target ? devicePath(target, '/system/virtio-win/status') : '/system/virtio-win/status'
      const { data } = await api.get(path)
      if (seq !== virtioCheckSeq) return
      virtioWinAvailable.value = data.available
      virtioWinImageId.value = data.imageId || null
    } catch {
      if (seq === virtioCheckSeq) virtioWinAvailable.value = false
    }
  }

  async function startVirtioWinDownload() {
    virtioWinError.value = ''
    virtioWinDownloading.value = true
    virtioWinProgress.value = 0
    virtioWinStatus.value = 'downloading'
    virtioProgress.stop()

    try {
      const target = opts.selectedDevice.value
      if (opts.selectedHostId.value && !target) {
        virtioWinError.value = 'The selected Device is no longer available. Pick a Device again.'
        virtioWinDownloading.value = false
        return
      }
      const path = target ? devicePath(target, '/system/virtio-win/download') : '/system/virtio-win/download'
      const { data } = await api.post(path)
      virtioWinImageId.value = data.imageId
      if (target && !isSelfDevice(target)) {
        // No SSE cross-device — poll the member image until ready.
        const { poll } = useTaskPoller()
        if (data.taskID) {
          const event = await poll(data.taskID, { path: deviceTaskPath(target, data.taskID) })
          if (event.status === 'completed') {
            virtioWinAvailable.value = true
            virtioWinDownloading.value = false
            return
          }
          virtioWinError.value = event.error || 'Download failed'
          virtioWinDownloading.value = false
          return
        }
        virtioWinAvailable.value = false
        virtioWinDownloading.value = false
        virtioWinError.value = 'Download started on the Device. Refresh this step shortly.'
        return
      }

      virtioProgress.start(data.imageId, {
        onProgress: (msg) => {
          const percent = imageProgressPercent(msg)
          if (percent != null) virtioWinProgress.value = percent
          virtioWinStatus.value = msg.status ?? 'downloading'
        },
        onReady: () => {
          virtioWinAvailable.value = true
          virtioWinDownloading.value = false
          imageStore.fetchAll()
        },
        onError: (msg) => {
          virtioWinError.value = msg?.error || 'Download failed'
          virtioWinDownloading.value = false
          if (virtioWinStatus.value !== 'ready') {
            checkVirtioWinStatus()
          }
        },
      })
    } catch (e: any) {
      virtioWinError.value = apiErrorMessage(e)
      virtioWinDownloading.value = false
    }
  }

  watch(opts.osType, async (os) => {
    if (os === 'windows') {
      await checkVirtioWinStatus()
    }
  })

  return {
    virtioWinAvailable,
    virtioWinImageId,
    virtioWinDownloading,
    virtioWinProgress,
    virtioWinStatus,
    virtioWinError,
    checkVirtioWinStatus,
    startVirtioWinDownload,
  }
}
