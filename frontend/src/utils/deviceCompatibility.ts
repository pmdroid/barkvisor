/** Filter/disable Devices for Create VM and template Deploy (PAS-34). Manual pick only. */

import type { CurrentHostCapabilities, HomeDeviceHealthSnapshot, VMTemplate } from '../api/types'
import {
  capabilitiesArchRunnable,
  capabilitiesFeatureSupported,
} from './capabilitiesParse'
import { imageArchSupportedOnHost, normalizeImageArch, templateArchSupportedOnHost, templateDeclaredArches } from './imageArch'
import { isSelfDevice } from './homeDeviceApi'

export type DevicePickOption = {
  hostId: string
  label: string
  role: string
  platformLine: string
  reachable: boolean
  compatible: boolean
  reasons: string[]
  recommended?: boolean
  recommendReasons?: string[]
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

export function createVMIncompatibilityReasons(
  device: HomeDeviceHealthSnapshot,
  opts: {
    guestArch?: string | null
    osType?: 'linux' | 'windows'
    requiredFeatures?: string[]
    capabilities?: CurrentHostCapabilities | null
  } = {},
): string[] {
  if (!isSelfDevice(device) && device.reachability !== 'ok') {
    return ['Device is unreachable']
  }
  const reasons: string[] = []
  const hostArch = pickedHostArch(device, opts.capabilities)
  const guest = opts.guestArch
  if (guest && hostArch && !imageArchSupportedOnHost(guest, hostArch)) {
    const have = normalizeImageArch(hostArch) ?? hostArch
    reasons.push(`Architecture (${guest}) is not compatible with this Device (${have}).`)
  }
  if (opts.osType === 'windows') {
    const arch = normalizeImageArch(hostArch)
    if (arch && arch !== 'arm64') {
      reasons.push('Windows guests are not available on this Device architecture.')
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
    return ['Device is unreachable']
  }
  if (opts.hasTemplate === false) {
    return ["Not in this Device's Library"]
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
    reasons,
    recommended: extra.recommended === true,
    recommendReasons: extra.recommendReasons ?? [],
  }
}
