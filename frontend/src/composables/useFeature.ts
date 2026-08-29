import { computed, reactive, toValue, type MaybeRefOrGetter } from 'vue'
import { useCapabilitiesStore } from '../stores/capabilities'

export { BRIDGE_MUTATION_ACTION_KEYS } from '../utils/linuxBridgeSetup'

/**
 * Wave 0 capability gates — current host only (PAS-38).
 *
 * | Feature               | Surfaces                                                      |
 * | --------------------- | ------------------------------------------------------------- |
 * | bridgedNetworking     | NetworkView, TemplateDeploy, CreateVM network pick            |
 * | managedBridgeDaemon   | SetupView skip. Networks never mutate the host daemon.        |
 * | hostBridgeManagement  | NetworkView Bridge setup (Linux checklist)                    |
 * | usbPassthrough        | CreateVM network step, CreateVM summary, VMDetail attach USB  |
 * | gpuPassthrough        | Device/Workload GPU copy. No QEMU vfio-pci attach (PAS-274).  |
 * | inAppUpdate           | Settings → Updates on a root .deb / .pkg appliance             |
 *
 * Prefer disable + server remediation over hide. Setup omits the macOS-only
 * bridge-install step instead of showing a dead wizard page.
 * Networks Bridge setup is `bridgeManagementMode` (linux-guide / macos-guide).
 */
export const FEATURE_CODES = [
  'bridgedNetworking',
  'managedBridgeDaemon',
  'hostBridgeManagement',
  'usbPassthrough',
  'gpuPassthrough',
  'inAppUpdate',
] as const

export type FeatureCode = (typeof FEATURE_CODES)[number]

/** Reactive current-host feature gate. */
export function useFeature(code: MaybeRefOrGetter<string>) {
  const caps = useCapabilitiesStore()

  return reactive({
    available: computed(() => caps.isSupported(toValue(code))),
    explanation: computed(() => caps.explanationFor(toValue(code))),
    detail: computed(() => caps.detailFor(toValue(code))),
    loaded: computed(() => caps.loaded),
  })
}

/** Drop bridged networks when the current host cannot use them. */
export function networksUsableOnHost<T extends { mode: string }>(
  networks: T[],
  bridgedOk: boolean,
): T[] {
  if (bridgedOk) return networks
  return networks.filter((n) => n.mode !== 'bridged')
}

export type BridgeManagementMode = 'linux-guide' | 'macos-guide' | 'hidden'

/** Which Networks Bridge-setup surface to show. Never a mutation toolbar. */
export function bridgeManagementMode(caps: {
  platform?: string | null
  supportsHostBridgeManagement?: boolean | null
  supportsManagedBridgeDaemon?: boolean | null
}): BridgeManagementMode {
  const platform = (caps.platform || '').toLowerCase()
  if (caps.supportsHostBridgeManagement === true || platform === 'linux') {
    return 'linux-guide'
  }
  if (
    caps.supportsManagedBridgeDaemon === true
    || platform === 'macos'
    || platform === 'darwin'
  ) {
    return 'macos-guide'
  }
  return 'hidden'
}

/**
 * Action keys the Networks Bridge-setup UI may render.
 * Guides are copyable text only — never setup / start / stop / remove.
 */
export function bridgeGuideActionKeys(
  mode: BridgeManagementMode,
): readonly string[] {
  switch (mode) {
    case 'linux-guide':
    case 'macos-guide':
    case 'hidden':
      return []
  }
}
