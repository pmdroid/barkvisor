/** Filter/disable Devices for Create VM and template Deploy (PAS-34). Manual pick only. */

import type { CurrentHostCapabilities, GuestTypeInfo, HomeDeviceHealthSnapshot, VMTemplate } from '../api/types'
import {
  capabilitiesArchRunnable,
  capabilitiesFeatureSupported,
} from './capabilitiesParse'
import { imageArchSupportedOnHost, normalizeImageArch, templateArchSupportedOnHost, templateDeclaredArches } from './imageArch'
import { isSelfDevice } from './homeDeviceApi'
import { reachabilityHint, reachabilityLabel } from './homeDeviceHealth'

export const DEVICE_LIBRARY_MISSING_REASON = "Not in this Device's Library"

function placementUnreachableReason(device: HomeDeviceHealthSnapshot): string {
  return reachabilityHint(device) || reachabilityLabel(device.reachability)
}

export type DevicePickOption = {
  hostId: string
  label: string
  role: string
  platformLine: string
  reachable: boolean
  compatible: boolean
  /** False when missing Library bytes — place-anyway is only for arch/capacity. */
  placeAnyway: boolean
  reasons: string[]
  recommended?: boolean
  recommendReasons?: string[]
}

export function reasonsAllowPlaceAnyway(reasons: string[]): boolean {
  return !reasons.includes(DEVICE_LIBRARY_MISSING_REASON)
}

export function deviceDisplayLabel(device: {
  displayName?: string | null
  hostId: string
}): string {
  if (device.displayName && device.displayName.trim()) return device.displayName
  return device.hostId
}

export function devicePlatformLine(device: HomeDeviceHealthSnapshot): string {
  const os = device.platform?.os
  const arch = device.platform?.arch
  if (os && arch) return `${os} · ${arch}`
  return os || arch || ''
}

function pickedHostArch(
  device: HomeDeviceHealthSnapshot,
  capabilities?: CurrentHostCapabilities | null,
): string | null {
  return capabilities?.hostArch || device.platform?.arch || null
}

/** True when capabilities advertise a Windows guest profile (optionally for `guestArch`). */
export function guestTypesSupportWindows(
  guestTypes: Array<Pick<GuestTypeInfo, 'id'> & Partial<Pick<GuestTypeInfo, 'osFamily' | 'arch'>>> | null | undefined,
  guestArch?: string | null,
): boolean {
  if (!guestTypes || guestTypes.length === 0) return false
  const want = guestArch ? (normalizeImageArch(guestArch) ?? guestArch) : null
  return guestTypes.some((guest) => {
    const isWindows = guest.osFamily === 'windows' || guest.id.startsWith('windows')
    if (!isWindows) return false
    if (!want) return true
    const profileArch = normalizeImageArch(guest.arch) ?? guest.arch
    return !profileArch || profileArch === want
  })
}

export function createVMIncompatibilityReasons(
  device: HomeDeviceHealthSnapshot,
  opts: {
    guestArch?: string | null
    osType?: 'linux' | 'windows'
    requiredFeatures?: string[]
    capabilities?: CurrentHostCapabilities | null
    hasImage?: boolean
  } = {},
): string[] {
  if (!isSelfDevice(device) && device.reachability !== 'ok') {
    return [placementUnreachableReason(device)]
  }
  if (opts.hasImage === false) {
    return [DEVICE_LIBRARY_MISSING_REASON]
  }
  const reasons: string[] = []
  const hostArch = pickedHostArch(device, opts.capabilities)
  const guest = opts.guestArch
  if (guest && hostArch && !imageArchSupportedOnHost(guest, hostArch)) {
    const have = normalizeImageArch(hostArch) ?? hostArch
    reasons.push(`Architecture (${guest}) is not compatible with this Device (${have}).`)
  }
  if (opts.osType === 'windows') {
    const types = opts.capabilities?.guestTypes
    if (types && types.length > 0) {
      const archMismatch = !!(guest && hostArch && !imageArchSupportedOnHost(guest, hostArch))
      const probe = archMismatch ? null : (opts.guestArch ?? hostArch)
      if (!guestTypesSupportWindows(types, probe)) {
        reasons.push('Windows guests are not available on this Device architecture.')
      }
    }
  }
  if (opts.requiredFeatures && opts.capabilities) {
    for (const feature of opts.requiredFeatures) {
      if (!capabilitiesFeatureSupported(opts.capabilities, feature)) {
        reasons.push(`Missing ${feature}`)
      }
    }
  }
  return reasons
}

export function templateIncompatibilityReasons(
  device: HomeDeviceHealthSnapshot,
  template: Pick<
    VMTemplate,
    'architectures' | 'imageByArch' | 'imageSlug' | 'compatible' | 'requiredFeatures' | 'networkMode' | 'minMemoryMB'
  >,
  opts: {
    capabilities?: CurrentHostCapabilities | null
    hasTemplate?: boolean
  } = {},
): string[] {
  if (!isSelfDevice(device) && device.reachability !== 'ok') {
    return [placementUnreachableReason(device)]
  }
  if (opts.hasTemplate === false) {
    return [DEVICE_LIBRARY_MISSING_REASON]
  }
  const reasons: string[] = []
  const hostArch = pickedHostArch(device, opts.capabilities)
  if (hostArch && !templateArchSupportedOnHost(template, hostArch)) {
    const want = templateDeclaredArches(template).join(', ') || 'unknown'
    const have = normalizeImageArch(hostArch) ?? hostArch
    reasons.push(`Architecture (${want}) is not compatible with this Device (${have}).`)
  }
  const caps = opts.capabilities
  if (caps) {
    if (!capabilitiesArchRunnable(caps, hostArch) && hostArch) {
      // runnableArches empty/unknown is fail-closed only when hostArch itself is unknown
    }
    for (const feature of template.requiredFeatures ?? []) {
      if (!capabilitiesFeatureSupported(caps, feature)) {
        reasons.push(`Missing ${feature}`)
      }
    }
    if (template.networkMode === 'bridged' && !caps.supportsBridgedNetworking) {
      reasons.push('Bridged networking is not available on this Device.')
    }
  }
  const total = device.resources?.memoryTotalMB
  if (template.minMemoryMB != null && total != null && total < template.minMemoryMB) {
    reasons.push(`Needs at least ${template.minMemoryMB} MB memory.`)
  }
  return reasons
}

export function toPickOption(
  device: HomeDeviceHealthSnapshot,
  reasons: string[],
  extra: { recommended?: boolean; recommendReasons?: string[] } = {},
): DevicePickOption {
  return {
    hostId: device.hostId,
    label: deviceDisplayLabel(device),
    role: String(device.role ?? 'member'),
    platformLine: devicePlatformLine(device),
    reachable: device.reachability === 'ok' || isSelfDevice(device),
    compatible: reasons.length === 0,
    placeAnyway: reasonsAllowPlaceAnyway(reasons),
    reasons,
    recommended: extra.recommended === true,
    recommendReasons: extra.recommendReasons ?? [],
  }
}
