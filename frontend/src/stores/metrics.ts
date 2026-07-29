import { defineStore } from 'pinia'
import { ref } from 'vue'
import type { MetricSample } from '../api/types'
import { useTicketedEventSource } from '../composables/useTicketedEventSource'

export const useMetricsStore = defineStore('metrics', () => {
  const samples = ref<MetricSample[]>([])
  const stream = useTicketedEventSource()

  function connect(vmId: string) {
    disconnect()
    samples.value = []

    // First fetch history
    const token = localStorage.getItem('token')
    fetch(`/api/vms/${vmId}/metrics?minutes=30`, {
      headers: { Authorization: `Bearer ${token}` },
    })
      .then(r => r.json())
      .then((data: MetricSample[]) => {
        samples.value = data
      })
      .catch(() => {})

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
    stream.stop()
    samples.value = []
  }

  return { samples, connect, disconnect }
})
