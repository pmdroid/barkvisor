import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { CapabilityDetail, CurrentHostCapabilities, SystemCapabilities } from '../api/types'

/**
 * Pinia store for the **current host** (process serving this SPA).
 *
 * Not multi-host state: when multi-device UI arrives, selected-device inventory
 * will sit beside this store (or replace it). Gate create-VM / network UI on
 * these fields instead of hardcoding platform assumptions.
 */
/**
 * Safe defaults match macOS full feature set so a failed fetch never hides
 * feature toggles on Mac. Arch-gated catalogs must use `hostArchKnown` so a
 * failed fetch does not silently filter everything to arm64 (PAS-48).
 */
const defaultCapabilities: CurrentHostCapabilities = {
  platform: 'macOS',
  supportsBridgedNetworking: true,
  supportsManagedBridgeDaemon: true,
  supportsUSBPassthrough: true,
  supportsInAppUpdate: true,
  accelerator: 'hvf',
  hostArch: 'arm64',
  hostCpuCount: 16,
  guestTypes: [],
  details: [],
}

export const useCapabilitiesStore = defineStore('capabilities', () => {
  /** Inventory projection for the host running this BarkVisor process. */
  const currentHost = ref<CurrentHostCapabilities>({ ...defaultCapabilities })
  /** @deprecated Prefer `currentHost` — same ref, legacy name. */
  const capabilities = currentHost
  const loaded = ref(false)
  const loading = ref(false)
  /** True only after a successful capabilities response with hostArch. */
  const hostArchKnown = ref(false)
  let loadPromise: Promise<void> | null = null

  const supportsBridgedNetworking = computed(() => currentHost.value.supportsBridgedNetworking)
  const supportsManagedBridgeDaemon = computed(() => currentHost.value.supportsManagedBridgeDaemon)
  const supportsUSBPassthrough = computed(() => currentHost.value.supportsUSBPassthrough)
  const supportsInAppUpdate = computed(() => currentHost.value.supportsInAppUpdate)
  const platform = computed(() => currentHost.value.platform)
  const accelerator = computed(() => currentHost.value.accelerator)
  const hostArch = computed(() => currentHost.value.hostArch)
  /** Max vCPUs assignable to a VM (= host online logical CPUs). */
  const hostCpuCount = computed(() => {
    const n = currentHost.value.hostCpuCount
    return typeof n === 'number' && n >= 1 ? n : defaultCapabilities.hostCpuCount!
  })
  const guestTypes = computed(() => currentHost.value.guestTypes ?? [])
  const details = computed(() => currentHost.value.details ?? [])

  function detailFor(code: string): CapabilityDetail | undefined {
    return details.value.find((d) => d.code === code)
  }

  /** Server remediation for an unsupported feature. Does not invent copy. */
  function explanationFor(code: string): string | undefined {
    const row = detailFor(code)
    if (!row || row.supported) return undefined
    return row.remediation || undefined
  }

  async function fetchCapabilities(): Promise<void> {
    if (loaded.value) return
    if (loadPromise) return loadPromise

    loading.value = true
    loadPromise = (async () => {
      try {
        // Public endpoint — works before login (setup wizard).
        // Projection of server HostInventory for this process's host.
        const res = await fetch('/api/system/capabilities')
        if (res.ok) {
          const data = (await res.json()) as SystemCapabilities
          currentHost.value = {
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
            details: Array.isArray(data.details) ? data.details : [],
          }
          hostArchKnown.value = typeof data.hostArch === 'string' && data.hostArch.length > 0
          // Only a 2xx response counts as loaded. A boot-time 502/network blip
          // must not permanently disable the PAS-48 arch gate (or Windows).
          loaded.value = true
        }
      } catch {
        // Keep defaults on network/server errors; hostArchKnown stays false.
      } finally {
        loading.value = false
        if (!loaded.value) {
          loadPromise = null
        }
      }
    })()

    return loadPromise
  }

  return {
    /** Current host capabilities (preferred). */
    currentHost,
    /** Alias of currentHost for existing callers. */
    capabilities,
    loaded,
    loading,
    hostArchKnown,
    supportsBridgedNetworking,
    supportsManagedBridgeDaemon,
    supportsUSBPassthrough,
    supportsInAppUpdate,
    platform,
    accelerator,
    hostArch,
    hostCpuCount,
    guestTypes,
    details,
    detailFor,
    explanationFor,
    fetchCapabilities,
  }
})
