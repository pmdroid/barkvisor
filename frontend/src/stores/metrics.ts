import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import type { MetricSample } from '../api/types'
import { useTicketedEventSource } from '../composables/useTicketedEventSource'
import { metricsHistoryFetchPath, shouldPollDeviceControl } from '../utils/editHome'
import type { DeviceApiTarget } from '../utils/homeDeviceApi'

export const useMetricsStore = defineStore('metrics', () => {
  const samples = ref<MetricSample[]>([])
  const stream = useTicketedEventSource()
  let pollTimer: ReturnType<typeof setInterval> | undefined
  let epoch = 0

  async function loadHistory(path: string, epochAtStart: number) {
    try {
      const { data } = await api.get<MetricSample[]>(path, { params: { minutes: 30 } })
      if (epochAtStart !== epoch) return
      samples.value = Array.isArray(data) ? data : []
    } catch {
      /* keep last successful snapshot */
    }
  }

  function connect(vmId: string, device?: DeviceApiTarget | null) {
    disconnect()
    const myEpoch = ++epoch
    samples.value = []

    if (device && shouldPollDeviceControl(device)) {
      const path = metricsHistoryFetchPath(device, vmId, 'running')
      if (!path) return
      void loadHistory(path, myEpoch)
      pollTimer = globalThis.setInterval(() => {
        void loadHistory(path, myEpoch)
      }, 5000)
      return
    }

    void loadHistory(`/vms/${encodeURIComponent(vmId)}/metrics`, myEpoch)
    stream.start({
      vmID: vmId,
      url: (ticket) => `/api/vms/${vmId}/metrics/stream?ticket=${ticket}`,
      reconnect: true,
      onMessage: (event) => {
        try {
          const sample: MetricSample = JSON.parse(event.data)
          samples.value.push(sample)
          // Keep max 360 samples (30 min at 5s interval)
          if (samples.value.length > 360) {
            samples.value = samples.value.slice(-360)
          }
        } catch {
          /* ignore */
        }
      },
    })
  }

  function disconnect() {
    epoch++
    if (pollTimer) {
      clearInterval(pollTimer)
      pollTimer = undefined
    }
    stream.stop()
    samples.value = []
  }

  return { samples, connect, disconnect }
})
