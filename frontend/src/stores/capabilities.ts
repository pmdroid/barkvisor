import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import type { CapabilityDetail, CurrentHostCapabilities, NetworkModeCapability, SystemCapabilities } from '../api/types'
import { normalizeImageArch, type ImageArch } from '../utils/imageArch'

/**
 * Pinia store for the **current host** (process serving this SPA).
 *
 * Not multi-host state: when multi-device UI arrives, selected-device inventory
 * will sit beside this store (or replace it). Gate create-VM / network UI on
 * these fields instead of hardcoding platform assumptions.
 */
/**
 * Fail-closed defaults (PAS-37). A failed / not-yet-loaded fetch must not invent
 * macOS feature flags or a runnable arch. Catalogs and USB/bridge/update UI stay
 * hidden until a real capabilities document arrives.
 */
const defaultCapabilities: CurrentHostCapabilities = {
  platform: '',
  supportsBridgedNetworking: false,
  supportsManagedBridgeDaemon: false,
  supportsUSBPassthrough: false,
  supportsInAppUpdate: false,
  accelerator: '',
  hostArch: '',
  hostCpuCount: 1,
  guestTypes: [],
  details: [],
  inventorySchemaVersion: undefined,
  runnableArches: [],
  networkModes: [
    { mode: 'nat', supported: true },
    { mode: 'bridged', supported: false },
    { mode: 'isolated', supported: true },
  ],
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
  const networkModes = computed(() => currentHost.value.networkModes ?? defaultCapabilities.networkModes!)
  /**
   * Host-runnable arches from the capabilities document.
   * Empty until a successful fetch — do not infer from guestTypes.
   */
  const runnableArches = computed<ImageArch[]>(() => {
    const listed = currentHost.value.runnableArches
    if (Array.isArray(listed) && listed.length > 0) {
      const out: ImageArch[] = []
      for (const raw of listed) {
        const n = normalizeImageArch(raw)
        if (n && !out.includes(n)) out.push(n)
      }
      if (out.length > 0) return out
    }
    if (hostArchKnown.value) {
      const n = normalizeImageArch(currentHost.value.hostArch)
      return n ? [n] : []
    }
    return []
  })

  function detailFor(code: string): CapabilityDetail | undefined {
    return details.value.find((d) => d.code === code)
  }

  /**
   * Current-host feature flag (PAS-38). Fail-closed: unknown codes are false
   * unless a capabilities `details` row explicitly says supported.
   */
  function isSupported(code: string): boolean {
    switch (code) {
      case 'bridgedNetworking':
        return currentHost.value.supportsBridgedNetworking
      case 'managedBridgeDaemon':
        return currentHost.value.supportsManagedBridgeDaemon
      case 'usbPassthrough':
        return currentHost.value.supportsUSBPassthrough
      case 'inAppUpdate':
        return currentHost.value.supportsInAppUpdate
      default:
        return detailFor(code)?.supported === true
    }
  }

  function isArchRunnable(arch: string | null | undefined): boolean {
    const img = normalizeImageArch(arch)
    if (!img) return false
    return runnableArches.value.includes(img)
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
            inventorySchemaVersion:
              typeof data.inventorySchemaVersion === 'number'
                ? data.inventorySchemaVersion
                : undefined,
            runnableArches: Array.isArray(data.runnableArches)
              ? data.runnableArches.filter((a): a is string => typeof a === 'string' && a.length > 0)
              : typeof data.hostArch === 'string' && data.hostArch.length > 0
                ? [data.hostArch]
                : [],
            networkModes: normalizeNetworkModes(
              data.networkModes,
              !!data.supportsBridgedNetworking,
              Array.isArray(data.details)
                ? data.details.find((d) => d.code === 'bridgedNetworking' && !d.supported)?.remediation
                : undefined,
            ),
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
    networkModes,
    runnableArches,
    detailFor,
    isSupported,
    isArchRunnable,
    explanationFor,
    fetchCapabilities,
  }
})

function normalizeNetworkModes(
  raw: NetworkModeCapability[] | undefined,
  bridgedOk: boolean,
  bridgedRemediation?: string | null,
): NetworkModeCapability[] {
  if (Array.isArray(raw) && raw.length > 0) {
    return raw.filter((m) => typeof m?.mode === 'string')
  }
  return [
    { mode: 'nat', supported: true },
    {
      mode: 'bridged',
      supported: bridgedOk,
      remediation: bridgedOk ? undefined : bridgedRemediation || undefined,
    },
    { mode: 'isolated', supported: true },
  ]
}
