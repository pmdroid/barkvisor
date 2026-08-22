/** Device chips for Library Images (PAS-221). Ready copies only. */

import type { HomeDeviceHealthSnapshot } from '../api/types'
import type { HomeImage, HomeImageCopy } from '../stores/homeLibrary'
import { deviceDisplayLabel } from './deviceCompatibility'
import { isSelfDevice } from './homeDeviceApi'

const SELF_PLACEHOLDER_HOST_ID = 'self'

function hostAliases(hostId: string, selfHostId?: string | null): string[] {
  const keys = [hostId]
  if (selfHostId && hostId === selfHostId && hostId !== SELF_PLACEHOLDER_HOST_ID) {
    keys.push(SELF_PLACEHOLDER_HOST_ID)
  }
  if (hostId === SELF_PLACEHOLDER_HOST_ID && selfHostId && selfHostId !== hostId) {
    keys.push(selfHostId)
  }
  return keys
}

export type LibraryImageDeviceChip = {
  hostId: string
  label: string
  self: boolean
  reachable: boolean
}

export function libraryImageCopyOnDevice(
  image: Pick<HomeImage, 'copies'>,
  hostId: string,
  selfHostId?: string | null,
): HomeImageCopy | undefined {
  const aliases = new Set(hostAliases(hostId, selfHostId))
  return image.copies.find((copy) => aliases.has(copy.hostId))
}

/** Chips from `sourceHostIds` (ready copies). Uploading/downloading copies stay off the row. */
export function readyLibraryImageDeviceChips(
  image: Pick<HomeImage, 'sourceHostIds' | 'copies'>,
  devices: HomeDeviceHealthSnapshot[],
  labelFor: (hostId: string) => string,
): LibraryImageDeviceChip[] {
  const ready = new Set(
    image.copies.filter((copy) => copy.status === 'ready').map((copy) => copy.hostId),
  )
  const byHost = new Map(devices.map((device) => [device.hostId, device]))
  const chips: LibraryImageDeviceChip[] = []
  for (const hostId of image.sourceHostIds) {
    if (!ready.has(hostId)) continue
    const device = byHost.get(hostId)
    const self = device ? isSelfDevice(device) : hostId === SELF_PLACEHOLDER_HOST_ID
    chips.push({
      hostId,
      label: device ? deviceDisplayLabel(device) : labelFor(hostId),
      self,
      reachable: device ? isSelfDevice(device) || device.reachability === 'ok' : true,
    })
  }
  return chips
}
