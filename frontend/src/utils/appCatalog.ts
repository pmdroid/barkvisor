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
    return `This Device is ${arch}. This app needs ${appArchLabel(app.arches)}.`
  }
  if (!dockerAvailable) {
    return 'This Device does not have dockerEngine.'
  }
  return ''
}

export function applicationSpecYaml(app: AppCatalogEntry, name: string): string {
  const compose = app.compose.replace(/\n/g, '\n    ')
  return `apiVersion: barkvisor.dev/v1
kind: Application
metadata:
  name: ${name}
spec:
  runtime: device
  compose: |
    ${compose}
`
}
