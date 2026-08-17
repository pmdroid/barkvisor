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
  let pollTimer: number | undefined

  async function loadHistory(path: string) {
    try {
      const { data } = await api.get<MetricSample[]>(path, { params: { minutes: 30 } })
      samples.value = Array.isArray(data) ? data : []
    } catch {
      samples.value = []
    }
  }

  function connect(vmId: string, device?: DeviceApiTarget | null) {
    disconnect()
    samples.value = []

    if (device && shouldPollDeviceControl(device)) {
      const path = metricsHistoryFetchPath(device, vmId, 'running')
      if (!path) return
      void loadHistory(path)
      pollTimer = globalThis.setInterval(() => {
        void loadHistory(path)
      }, 5000)
      return
    }

    void loadHistory(`/vms/${encodeURIComponent(vmId)}/metrics`)
    stream.start({
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
    if (pollTimer) {
      clearInterval(pollTimer)
      pollTimer = undefined
    }
    stream.stop()
    samples.value = []
  }

  return { samples, connect, disconnect }
})
