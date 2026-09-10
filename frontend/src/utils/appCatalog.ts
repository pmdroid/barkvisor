import { normalizeImageArch } from './imageArch'
import type { AppCatalogEntry } from '../api/types'

export function appSupportsDeviceArch(app: AppCatalogEntry, deviceArch: string | null | undefined): boolean {
  if (!app.arches.length) return true
  const want = normalizeImageArch(deviceArch)
  if (!want) return false
  return app.arches.some((arch) => normalizeImageArch(arch) === want)
}

export function appArchLabel(arches: string[]): string {
  const labels = [...new Set(arches.map((arch) => normalizeImageArch(arch) ?? arch))]
  return labels.join(' · ') || 'any'
}

export function appSourceLabel(source: string): string {
  if (source === 'linuxserver') return 'LinuxServer'
  if (source === 'big-bear-universal') return 'Big Bear'
  return source
}

export function appCatalogKey(app: { source: string; id: string }): string {
  return `${app.source}:${app.id}`
}

export function appInstallBlockedReason(
  app: AppCatalogEntry,
  deviceArch: string | null | undefined,
  dockerAvailable: boolean,
): string {
  if (app.unsupportedReasons.length) {
    return app.unsupportedReasons.join(', ')
  }
  if (!appSupportsDeviceArch(app, deviceArch)) {
    const arch = normalizeImageArch(deviceArch) ?? deviceArch ?? 'unknown'
    return `The selected Device is ${arch}. The app needs ${appArchLabel(app.arches)}.`
  }
  if (!dockerAvailable) {
    return 'The selected Device does not have dockerEngine.'
  }
  return ''
}

export function applicationSpecYaml(app: AppCatalogEntry, name: string): string {
  const compose = app.compose.replace(/\n/g, '\n    ')
  const safeName = JSON.stringify(name.replace(/[\n\r]/g, ''))
  return `apiVersion: barkvisor.dev/v1
kind: Application
metadata:
  name: ${safeName}
spec:
  runtime: device
  compose: |
    ${compose}
`
}
