/** Settings SPA tabs. `?tab=` uses these ids (`pairing` is pairing + mobile login QR). */
export const SETTINGS_TABS = [
  'home',
  'pairing',
  'library',
  'repositories',
  'apikeys',
  'sshkeys',
  'passkeys',
  'audit',
  'updates',
] as const

export type SettingsTab = (typeof SETTINGS_TABS)[number]

export const DEFAULT_SETTINGS_TAB: SettingsTab = 'apikeys'

export const SSH_KEYS_SETTINGS_HREF = '/settings?tab=sshkeys'

export const REPOSITORIES_SETTINGS_HREF = '/settings?tab=repositories'

export function isSettingsTab(value: string): value is SettingsTab {
  return (SETTINGS_TABS as readonly string[]).includes(value)
}

export function isPairingTab(tab: string | null | undefined): tab is 'pairing' {
  return tab === 'pairing'
}

/** 1s expiry tick only while Pairing is showing an offer. */
export function shouldRunPairingTick(
  tab: string | null | undefined,
  hasOffer: boolean,
): boolean {
  return isPairingTab(tab) && hasOffer
}

type QueryTabValue = string | null | undefined | Array<string | null | undefined>
type SettingsTabQuery = QueryTabValue | { tab?: QueryTabValue }

function firstQueryString(value: QueryTabValue): string | undefined {
  const raw = Array.isArray(value) ? value[0] : value
  return typeof raw === 'string' ? raw : undefined
}

export function settingsQueryTab(q: SettingsTabQuery): string | undefined {
  return q != null && typeof q === 'object' && !Array.isArray(q) && 'tab' in q
    ? firstQueryString(q.tab)
    : firstQueryString(q as QueryTabValue)
}

export function isLegacyDisksSettingsTab(value: string | undefined): boolean {
  return value === 'disks'
}

export function settingsTabFromQuery(q: SettingsTabQuery): SettingsTab | undefined {
  const raw = settingsQueryTab(q)
  if (!raw) return undefined
  return isSettingsTab(raw) ? raw : undefined
}
