/** Pick which Device should receive a catalog Download (PAS-34 Library). */

import { imageArchSupportedOnHost, normalizeImageArch } from './imageArch'
import { canCallDeviceAPI, isSelfDevice, type DeviceApiTarget } from './homeDeviceApi'

export type CatalogDownloadDevice = DeviceApiTarget & {
  displayName?: string | null
  platform?: { arch?: string | null } | null
}

/** Reachable Device whose CPU can run this catalog image. Prefers this Device. */
export function deviceForCatalogImage<T extends CatalogDownloadDevice>(
  imageArch: string | null | undefined,
  devices: T[],
): T | null {
  const want = normalizeImageArch(imageArch)
  if (!want) return null
  const compatible = devices.filter((device) => {
    if (!canCallDeviceAPI(device)) return false
    return imageArchSupportedOnHost(want, device.platform?.arch)
  })
  return compatible.find((device) => isSelfDevice(device)) ?? compatible[0] ?? null
}
