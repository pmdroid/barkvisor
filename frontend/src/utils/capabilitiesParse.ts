import type { CurrentHostCapabilities, NetworkModeCapability, SystemCapabilities } from '../api/types'
import { normalizeImageArch, type ImageArch } from './imageArch'

/** Fail-closed defaults (PAS-37). */
export const defaultCapabilities: CurrentHostCapabilities = {
  platform: '',
  supportsBridgedNetworking: false,
  supportsManagedBridgeDaemon: false,
  supportsHostBridgeManagement: false,
  supportsUSBPassthrough: false,
  supportsInAppUpdate: false,
  supportsGPUPassthrough: false,
  supportsVFIO: false,
  accelerator: '',
  hostArch: '',
  hostCpuCount: 1,
  guestTypes: [],
  details: [],
  inventorySchemaVersion: undefined,
  runnableArches: [],
  networkModes: [
    { mode: 'nat', supported: true },
    { mode: 'bridged', supported: false },
    { mode: 'isolated', supported: true },
  ],
}

/** Normalize a /system/capabilities document (local or proxied). */
export function parseSystemCapabilities(data: Partial<SystemCapabilities> | null | undefined): CurrentHostCapabilities {
  const doc = data ?? {}
  return {
    platform: doc.platform ?? defaultCapabilities.platform,
    supportsBridgedNetworking: !!doc.supportsBridgedNetworking,
    supportsManagedBridgeDaemon: !!doc.supportsManagedBridgeDaemon,
    supportsHostBridgeManagement: !!doc.supportsHostBridgeManagement,
    supportsUSBPassthrough: !!doc.supportsUSBPassthrough,
    supportsInAppUpdate: !!doc.supportsInAppUpdate,
    supportsGPUPassthrough: !!doc.supportsGPUPassthrough,
    supportsVFIO: !!doc.supportsVFIO,
    accelerator: doc.accelerator ?? defaultCapabilities.accelerator,
    hostArch: doc.hostArch ?? defaultCapabilities.hostArch,
    hostCpuCount:
      typeof doc.hostCpuCount === 'number' && doc.hostCpuCount >= 1
        ? doc.hostCpuCount
        : defaultCapabilities.hostCpuCount,
    guestTypes: Array.isArray(doc.guestTypes) ? doc.guestTypes : [],
    details: Array.isArray(doc.details) ? doc.details : [],
    inventorySchemaVersion:
      typeof doc.inventorySchemaVersion === 'number'
        ? doc.inventorySchemaVersion
        : undefined,
    runnableArches: Array.isArray(doc.runnableArches)
      ? doc.runnableArches.filter((a): a is string => typeof a === 'string' && a.length > 0)
      : typeof doc.hostArch === 'string' && doc.hostArch.length > 0
        ? [doc.hostArch]
        : [],
    networkModes: normalizeNetworkModes(
      doc.networkModes,
      !!doc.supportsBridgedNetworking,
      Array.isArray(doc.details)
        ? doc.details.find((d) => d.code === 'bridgedNetworking' && !d.supported)?.remediation
        : undefined,
    ),
  }
}

export function capabilitiesFeatureSupported(
  caps: CurrentHostCapabilities,
  code: string,
): boolean {
  switch (code) {
    case 'bridgedNetworking':
      return caps.supportsBridgedNetworking
    case 'managedBridgeDaemon':
      return caps.supportsManagedBridgeDaemon
    case 'hostBridgeManagement':
      return !!caps.supportsHostBridgeManagement
    case 'usbPassthrough':
      return caps.supportsUSBPassthrough
    case 'inAppUpdate':
      return caps.supportsInAppUpdate
    case 'gpuPassthrough':
      return caps.supportsGPUPassthrough === true
    case 'vfio':
      return caps.supportsVFIO === true
    default:
      return caps.details?.find((d) => d.code === code)?.supported === true
  }
}

export function capabilitiesArchRunnable(
  caps: CurrentHostCapabilities,
  arch: string | null | undefined,
): boolean {
  const img = normalizeImageArch(arch)
  if (!img) return false
  const listed = caps.runnableArches
  if (Array.isArray(listed) && listed.length > 0) {
    return listed.some((raw) => normalizeImageArch(raw) === img)
  }
  return normalizeImageArch(caps.hostArch) === img
}

export function normalizeNetworkModes(
  raw: NetworkModeCapability[] | undefined,
  bridgedOk: boolean,
  bridgedRemediation?: string | null,
): NetworkModeCapability[] {
  if (Array.isArray(raw) && raw.length > 0) {
    return raw.filter((m) => typeof m?.mode === 'string')
  }
  return [
    { mode: 'nat', supported: true },
    {
      mode: 'bridged',
      supported: bridgedOk,
      remediation: bridgedOk ? undefined : bridgedRemediation || undefined,
    },
    { mode: 'isolated', supported: true },
  ]
}

export type { ImageArch }
