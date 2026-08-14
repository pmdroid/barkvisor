import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import api from '../api/client'
import type { HomeDeviceHealthReport, HomeDeviceHealthSnapshot } from '../api/types'

export const useDevicesStore = defineStore('devices', () => {
  const report = ref<HomeDeviceHealthReport | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)

  const devices = computed(() => report.value?.devices ?? [])
  const totals = computed(() => report.value?.totals ?? null)
  const selfDevice = computed(
    () => devices.value.find((row) => row.role === 'self') ?? null,
  )

  async function fetchHealth(): Promise<void> {
    loading.value = true
    try {
      const { data } = await api.get<HomeDeviceHealthReport>('/home/devices/health')
      report.value = data
      error.value = null
    } catch (err) {
      error.value = err instanceof Error ? err.message : 'Unable to load Devices'
    } finally {
      loading.value = false
    }
  }

  function deviceLabel(row: HomeDeviceHealthSnapshot): string {
    if (row.displayName && row.displayName.trim()) return row.displayName
    return row.hostId
  }

  return {
    report,
    loading,
    error,
    devices,
    totals,
    selfDevice,
    fetchHealth,
    deviceLabel,
  }
})
