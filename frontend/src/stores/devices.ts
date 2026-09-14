import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import api from '../api/client'
import type { HomeDeviceHealthReport, HomeDeviceHealthSnapshot } from '../api/types'

export const HOME_REACHABILITY_REFRESH_MS = 5_000

export const useDevicesStore = defineStore('devices', () => {
  const report = ref<HomeDeviceHealthReport | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)
  let fetchSeq = 0
  let inFlight: Promise<void> | null = null
  let lastSuccessfulFetchAt = 0
  let pollTimer: ReturnType<typeof setInterval> | null = null

  const devices = computed(() => report.value?.devices ?? [])
  const totals = computed(() => report.value?.totals ?? null)
  const selfDevice = computed(
    () => devices.value.find((row) => row.role === 'self') ?? null,
  )

  function deviceByHostId(hostId: string): HomeDeviceHealthSnapshot | null {
    return devices.value.find((row) => row.hostId === hostId) ?? null
  }

  async function fetchHealth({ force = false }: { force?: boolean } = {}): Promise<void> {
    if (inFlight) return inFlight
    if (!force && report.value && Date.now() - lastSuccessfulFetchAt < HOME_REACHABILITY_REFRESH_MS) return
    const seq = ++fetchSeq
    loading.value = true
    inFlight = (async () => {
      try {
        const { data } = await api.get<HomeDeviceHealthReport>('/home/devices/health')
        if (seq !== fetchSeq) return
        report.value = data
        lastSuccessfulFetchAt = Date.now()
        error.value = null
      } catch (err) {
        if (seq !== fetchSeq) return
        error.value = err instanceof Error ? err.message : 'Unable to load Devices'
      } finally {
        if (seq === fetchSeq) loading.value = false
        inFlight = null
      }
    })()
    return inFlight
  }

  function startReachabilityPolling(): void {
    if (pollTimer) return
    void fetchHealth()
    pollTimer = setInterval(() => { void fetchHealth() }, HOME_REACHABILITY_REFRESH_MS)
  }

  function stopReachabilityPolling(): void {
    if (!pollTimer) return
    clearInterval(pollTimer)
    pollTimer = null
  }

  async function removeDevice(hostId: string): Promise<void> {
    await api.delete(`/home/devices/${encodeURIComponent(hostId)}`)
    if (!report.value) return
    const remaining = report.value.devices.filter((row) => row.hostId !== hostId)
    const healthCounts: Record<string, number> = {}
    let workloadCount = 0
    let hasWorkloadCount = false
    for (const row of remaining) {
      for (const [name, count] of Object.entries(row.healthCounts ?? {})) {
        healthCounts[name] = (healthCounts[name] ?? 0) + count
      }
      if (row.workloadCount != null) {
        workloadCount += row.workloadCount
        hasWorkloadCount = true
      }
    }
    report.value = {
      devices: remaining,
      totals: {
        devices: remaining.length,
        reachable: remaining.filter((row) => row.reachability === 'ok').length,
        unreachable: remaining.filter((row) => row.reachability !== 'ok').length,
        workloadCount: hasWorkloadCount ? workloadCount : null,
        healthCounts,
      },
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
    startReachabilityPolling,
    stopReachabilityPolling,
    removeDevice,
    deviceLabel,
  }
})
