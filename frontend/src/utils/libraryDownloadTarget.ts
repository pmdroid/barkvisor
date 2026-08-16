/** Pick which Device should receive a catalog Download (PAS-34 Library). */

import { imageArchSupportedOnHost, normalizeImageArch } from './imageArch'
import { canCallDeviceAPI, isSelfDevice, type DeviceApiTarget } from './homeDeviceApi'

export type CatalogDownloadDevice = DeviceApiTarget & {
  displayName?: string | null
  platform?: { arch?: string | null } | null
}

/**
 * Catalog Download writes into a Device Library.
 * Prefer the configured Library depot when that Device is reachable — the depot
 * stores files of any arch. Otherwise pick a reachable Device that can run the
 * guest, preferring This Device.
 */
/** Refuse catalog Download when Device health is missing or the last fetch failed. */
export function catalogDownloadBlockedReason(opts: {
  healthError: string | null
  hasReport: boolean
}): string | null {
  if (opts.healthError) return 'Cannot download until Device health is available.'
  if (!opts.hasReport) return 'Cannot download until Device health is available.'
  return null
}

export function deviceForCatalogImage<T extends CatalogDownloadDevice>(
  imageArch: string | null | undefined,
  devices: T[],
  depotHostId?: string | null,
): T | null {
  const depotId = depotHostId?.trim()
  if (depotId) {
    const depot = devices.find((device) => device.hostId === depotId)
    if (depot && canCallDeviceAPI(depot)) return depot
  }
  const want = normalizeImageArch(imageArch)
  if (!want) return null
  const compatible = devices.filter((device) => {
    if (!canCallDeviceAPI(device)) return false
    return imageArchSupportedOnHost(want, device.platform?.arch)
  })
  return compatible.find((device) => isSelfDevice(device)) ?? compatible[0] ?? null
}
