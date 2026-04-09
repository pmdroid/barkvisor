import { defineStore } from 'pinia'
import { ref } from 'vue'
import type { MetricSample } from '../api/types'
import { getWSTicket } from '../api/client'

export const useMetricsStore = defineStore('metrics', () => {
  const samples = ref<MetricSample[]>([])
  let eventSource: EventSource | null = null
  let reconnectTimeout: ReturnType<typeof setTimeout> | null = null
  let reconnectDelay = 1000
  let lastVmId: string | null = null
  const MAX_RECONNECT_DELAY = 30000
  const MAX_RECONNECT_ATTEMPTS = 10
  let reconnectAttempts = 0

  function connect(vmId: string) {
    disconnect()
    samples.value = []
    lastVmId = vmId
    reconnectDelay = 1000
    reconnectAttempts = 0

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

    connectSSE(vmId)
  }

  async function connectSSE(vmId: string) {
    let ticket: string
    try {
      ticket = await getWSTicket()
    } catch { return }
    eventSource = new EventSource(`/api/vms/${vmId}/metrics/stream?ticket=${ticket}`)
    eventSource.onopen = () => {
      reconnectDelay = 1000
      reconnectAttempts = 0
    }
    eventSource.onmessage = (event) => {
      const sample: MetricSample = JSON.parse(event.data)
      samples.value.push(sample)
      // Keep max 360 samples (30 min at 5s interval)
      if (samples.value.length > 360) {
        samples.value = samples.value.slice(-360)
      }
    }
    eventSource.onerror = () => {
      eventSource?.close()
      eventSource = null
      reconnectAttempts++
      if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS || !lastVmId) return
      reconnectTimeout = setTimeout(() => {
        reconnectTimeout = null
        if (lastVmId) connectSSE(lastVmId)
      }, reconnectDelay)
      reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY)
    }
  }

  function disconnect() {
    if (reconnectTimeout) { clearTimeout(reconnectTimeout); reconnectTimeout = null }
    if (eventSource) {
      eventSource.close()
      eventSource = null
    }
    lastVmId = null
    samples.value = []
  }

  return { samples, connect, disconnect }
})
