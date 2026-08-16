import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import api from '../api/client'
import type { HomeDeviceHealthReport, HomeDeviceHealthSnapshot } from '../api/types'

export const useDevicesStore = defineStore('devices', () => {
  const report = ref<HomeDeviceHealthReport | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)
  let fetchSeq = 0

  const devices = computed(() => report.value?.devices ?? [])
  const totals = computed(() => report.value?.totals ?? null)
  const selfDevice = computed(
    () => devices.value.find((row) => row.role === 'self') ?? null,
  )

  function deviceByHostId(hostId: string): HomeDeviceHealthSnapshot | null {
    return devices.value.find((row) => row.hostId === hostId) ?? null
  }

  async function fetchHealth(): Promise<void> {
    const seq = ++fetchSeq
    loading.value = true
    try {
      const { data } = await api.get<HomeDeviceHealthReport>('/home/devices/health')
      if (seq !== fetchSeq) return
      report.value = data
      error.value = null
    } catch (err) {
      if (seq !== fetchSeq) return
      error.value = err instanceof Error ? err.message : 'Unable to load Devices'
    } finally {
      if (seq === fetchSeq) loading.value = false
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
    deviceByHostId,
    fetchHealth,
    deviceLabel,
  }
})
