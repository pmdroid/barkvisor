import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { SystemCapabilities } from '../api/types'

/** Safe defaults match macOS full feature set so a failed fetch never hides UI on Mac. */
const defaultCapabilities: SystemCapabilities = {
  platform: 'macOS',
  supportsBridgedNetworking: true,
  supportsManagedBridgeDaemon: true,
  supportsUSBPassthrough: true,
  supportsInAppUpdate: true,
  accelerator: 'hvf',
  hostArch: 'arm64',
  hostCpuCount: 16,
  guestTypes: [],
}

export const useCapabilitiesStore = defineStore('capabilities', () => {
  const capabilities = ref<SystemCapabilities>({ ...defaultCapabilities })
  const loaded = ref(false)
  const loading = ref(false)
  let loadPromise: Promise<void> | null = null

  const supportsBridgedNetworking = computed(() => capabilities.value.supportsBridgedNetworking)
  const supportsManagedBridgeDaemon = computed(() => capabilities.value.supportsManagedBridgeDaemon)
  const supportsUSBPassthrough = computed(() => capabilities.value.supportsUSBPassthrough)
  const supportsInAppUpdate = computed(() => capabilities.value.supportsInAppUpdate)
  const platform = computed(() => capabilities.value.platform)
  const accelerator = computed(() => capabilities.value.accelerator)
  const hostArch = computed(() => capabilities.value.hostArch)
  /** Max vCPUs assignable to a VM (= host online logical CPUs). */
  const hostCpuCount = computed(() => {
    const n = capabilities.value.hostCpuCount
    return typeof n === 'number' && n >= 1 ? n : defaultCapabilities.hostCpuCount!
  })
  const guestTypes = computed(() => capabilities.value.guestTypes ?? [])

  async function fetchCapabilities(): Promise<void> {
    if (loaded.value) return
    if (loadPromise) return loadPromise

    loading.value = true
    loadPromise = (async () => {
      try {
        // Public endpoint — works before login (setup wizard).
        const res = await fetch('/api/system/capabilities')
        if (res.ok) {
          const data = (await res.json()) as SystemCapabilities
          capabilities.value = {
            platform: data.platform ?? defaultCapabilities.platform,
            supportsBridgedNetworking: !!data.supportsBridgedNetworking,
            // Older servers omit the field — treat as product-bridge-only platforms.
            supportsManagedBridgeDaemon: !!data.supportsManagedBridgeDaemon,
            supportsUSBPassthrough: !!data.supportsUSBPassthrough,
            supportsInAppUpdate: !!data.supportsInAppUpdate,
            accelerator: data.accelerator ?? defaultCapabilities.accelerator,
            hostArch: data.hostArch ?? defaultCapabilities.hostArch,
            hostCpuCount:
              typeof data.hostCpuCount === 'number' && data.hostCpuCount >= 1
                ? data.hostCpuCount
                : defaultCapabilities.hostCpuCount,
            guestTypes: Array.isArray(data.guestTypes) ? data.guestTypes : [],
          }
        }
      } catch {
        // Keep defaults on network/server errors
      } finally {
        loaded.value = true
        loading.value = false
      }
    })()

    return loadPromise
  }

  return {
    capabilities,
    loaded,
    loading,
    supportsBridgedNetworking,
    supportsManagedBridgeDaemon,
    supportsUSBPassthrough,
    supportsInAppUpdate,
    platform,
    accelerator,
    hostArch,
    hostCpuCount,
    guestTypes,
    fetchCapabilities,
  }
})
