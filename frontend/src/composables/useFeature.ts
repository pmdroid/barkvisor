import { computed, reactive, toValue, type MaybeRefOrGetter } from 'vue'
import { useCapabilitiesStore } from '../stores/capabilities'

/**
 * Wave 0 capability gates — current host only (PAS-38).
 *
 * | Feature               | Surfaces                                                      |
 * | --------------------- | ------------------------------------------------------------- |
 * | bridgedNetworking     | NetworkView, TemplateDeploy, CreateVM network pick            |
 * | managedBridgeDaemon   | NetworkView Manage Bridges (macOS), SetupView skip            |
 * | hostBridgeManagement  | NetworkView Manage Bridges (Linux checklist)                  |
 * | usbPassthrough        | CreateVM network step, CreateVM summary, VMDetail attach USB  |
 * | inAppUpdate           | SettingsView updates tab                                      |
 *
 * Prefer disable + server remediation over hide. Setup omits the macOS-only
 * bridge-install step instead of showing a dead wizard page.
 */
export const FEATURE_CODES = [
  'bridgedNetworking',
  'managedBridgeDaemon',
  'hostBridgeManagement',
  'usbPassthrough',
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
