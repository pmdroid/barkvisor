import type { HostBridgeApplyRequest, HostBridgeReadiness } from '../api/types'
import type { GuestCommandGroup } from './guestAgentInstall'
import {
  HOST_BRIDGE_ACL_PATH,
  HOST_BRIDGE_HELPER_PATH,
  HOST_BRIDGE_SUGGESTED,
} from './hostBridgeFacts'

/** Legacy mutation keys — UI uses Apply/Revert on both platforms. Remove stays gone. */
export const BRIDGE_MUTATION_ACTION_KEYS = ['setup', 'start', 'stop', 'remove'] as const
export type BridgeMutationActionKey = (typeof BRIDGE_MUTATION_ACTION_KEYS)[number]
export const MACOS_SOCKET_VMNET_ACTION_KEYS = ['setup', 'start', 'stop'] as const

/**
 * Cached host-bridge facts belong to the Device (and guide mode) currently shown.
 * Pass mode when switching Linux ↔ macOS so a shared snapshot cannot leak commands.
 */
export function readinessAppliesTo(
  hostId: string,
  snapshotHostId: string | null | undefined,
  mode?: string,
  snapshotMode?: string | null,
): boolean {
  if (snapshotHostId == null || snapshotHostId !== hostId) return false
  if (mode != null && snapshotMode !== mode) return false
  return true
}

/** Matches SocketVmnetDiscovery.installHint. Never `sudo brew install`. */
export const SOCKET_VMNET_INSTALL_COMMANDS = [
  'brew install socket_vmnet',
].join('\n')

/** Copyable Linux host-bridge steps (PAS-222). Prefer remediations from HostBridgeFacts. */
export function linuxBridgeSetupGroups(ready: HostBridgeReadiness): GuestCommandGroup[] {
  if (ready.remediations && ready.remediations.length > 0) {
    return ready.remediations.map((step) => ({
      id: step.id,
      label: step.label,
      commands: step.commands,
    }))
  }

  const br = ready.suggestedBridge || HOST_BRIDGE_SUGGESTED
  const helper = ready.helperPath || HOST_BRIDGE_HELPER_PATH
  const groups: GuestCommandGroup[] = []

  if (ready.bridges.length === 0) {
    groups.push({
      id: 'create-bridge',
      label: `Create ${br}`,
      commands: linuxBridgeApplyCommands(ready).join('\n'),
    })
  }

  if (ready.aclAllowsSuggested !== true) {
    groups.push({
      id: 'allow-acl',
      label: `Allow ${br} in qemu-bridge.conf`,
      commands: [
        `# barkvisor:allow-${br}`,
        `printf '%s\\n%s\\n' '# barkvisor:allow-${br}' 'allow ${br}' | sudo tee -a ${HOST_BRIDGE_ACL_PATH}`,
      ].join('\n'),
    })
  }

  if (!ready.helperSetuid) {
    groups.push({
      id: 'setuid-helper',
      label: 'Setuid qemu-bridge-helper',
      commands: `sudo chmod u+s ${helper}`,
    })
  }

  return groups
}

/** Shown when the Device binary is older than PAS-222 (no readiness route). */
export const linuxBridgeFallbackReadiness: HostBridgeReadiness = {
  helperPath: HOST_BRIDGE_HELPER_PATH,
  helperSetuid: false,
  suggestedBridge: HOST_BRIDGE_SUGGESTED,
  aclAllowsSuggested: false,
  bridges: [],
  defaultRouteInterface: null,
  onlyUplink: false,
  ready: false,
}

export function linuxBridgeStatusSummary(
  ready: HostBridgeReadiness,
  deviceName?: string,
): string {
  const name = deviceName?.trim() || 'This machine'
  if (ready.ready) {
    const names = ready.bridges.map((b) => b.name).join(', ')
    return `${name} is ready for Bridged networks (${names || ready.suggestedBridge}).`
  }
  if (ready.onlyUplink) {
    return `${name} has a single uplink. Do not enslave it into a bridge (you can lose SSH). Prefer NAT, or add another NIC first.`
  }
  return `${name} is not ready for Bridged networks yet. Run the steps below, then Re-check.`
}

/** Copyable macOS steps: socket_vmnet + optional networksetup for Device address. */
export function macosSocketVmnetSetupGroups(
  ready?: HostBridgeReadiness | null,
): GuestCommandGroup[] {
  if (ready?.remediations && ready.remediations.length > 0) {
    return ready.remediations.map((step) => ({
      id: step.id,
      label: step.label,
      commands: step.commands,
    }))
  }
  const iface = ready?.defaultRouteInterface || 'en0'
  const groups: GuestCommandGroup[] = []
  if (!ready?.ready) {
    groups.push({
      id: 'homebrew-socket-vmnet',
      label: 'Install socket_vmnet (the Device starts the service)',
      commands: SOCKET_VMNET_INSTALL_COMMANDS,
    })
  }
  groups.push({
    id: 'device-address',
    label: 'Device address (Apply in Networks or API)',
    commands: [
      'Networks → Host interfaces → select LAN NIC → Apply.',
      '# After Apply: Keep changes within 30s in the SPA (POST action commit).',
      'networksetup -listallhardwareports',
      `curl -sS -X POST http://127.0.0.1:7777/api/system/bridges \\`,
      `  -H 'Content-Type: application/json' \\`,
      `  -d '{"interface":"${iface}","action":"apply","confirm":true,"addressing":"dhcp"}'`,
    ].join('\n'),
  })
  return groups
}

export function macosSocketVmnetStatusSummary(
  ready?: HostBridgeReadiness | null,
  deviceName?: string,
): string {
  const name = deviceName?.trim() || 'This machine'
  if (!ready) {
    return `Could not read socket_vmnet status on ${name}. Run the steps below, then Re-check.`
  }
  if (ready.ready) {
    const names = ready.bridges.map((b) => b.name).join(', ')
    return `${name} is ready for Bridged networks (${names || 'socket_vmnet'}).`
  }
  return `${name} is not ready for Bridged networks yet. Install socket_vmnet with Homebrew (not sudo brew install). The Device starts the service. Then Re-check.`
}

/** Equivalent apply hints when server remediations are absent. Prefer Networks → Apply. */
export function linuxBridgeApplyCommands(ready: HostBridgeReadiness): string[] {
  const br = ready.suggestedBridge || HOST_BRIDGE_SUGGESTED
  const nic = ready.defaultRouteInterface || '<wired-uplink>'
  return [
    `Networks → Host interfaces → select ${nic} → Apply.`,
    `# After Apply: Keep changes within 30s in the SPA (POST action commit) or the host auto-reverts.`,
    `curl -sS -X POST http://127.0.0.1:7777/api/system/bridges \\`,
    `  -H 'Content-Type: application/json' \\`,
    `  -d '{"interface":"${nic}","action":"apply","confirm":true,"addressing":"dhcp"}'`,
    `# Revert foreign: DELETE /api/system/bridges/${br}. Delete owned: POST action delete.`,
  ]
}

export function buildLinuxBridgeApplyBody(input: {
  nic?: string
  confirm?: boolean
  addressing: 'dhcp' | 'static'
  address?: string
  gateway?: string
  dns?: string
  addresses?: HostBridgeApplyRequest['addresses']
}): HostBridgeApplyRequest {
  if (input.addresses?.length) {
    const body: HostBridgeApplyRequest = {
      interface: input.nic,
      action: 'apply',
      confirm: input.confirm ?? false,
      addresses: input.addresses,
    }
    const gateway = input.gateway?.trim()
    if (gateway) body.gateway = gateway
    const dns = input.dns?.split(/[,\s]+/).map((s) => s.trim()).filter(Boolean) ?? []
    if (dns.length) body.dns = dns
    return body
  }
  const body: HostBridgeApplyRequest = {
    interface: input.nic,
    action: 'apply',
    addressing: input.addressing,
    confirm: input.confirm ?? false,
  }
  if (input.addressing === 'static') {
    const address = input.address?.trim()
    if (address) body.address = address
    const gateway = input.gateway?.trim()
    if (gateway) body.gateway = gateway
    const dns = input.dns?.split(/[,\s]+/).map((s) => s.trim()).filter(Boolean) ?? []
    if (dns.length) body.dns = dns
  }
  return body
}

export function linuxBridgeCanApply(caps: {
  platform?: string | null
  supportsHostMutation?: boolean | null
  supportsHostBridgeManagement?: boolean | null
}): boolean {
  const platform = (caps.platform || '').toLowerCase()
  if (platform === 'macos' || platform === 'darwin') return false
  if (caps.supportsHostMutation === true) return true
  return caps.supportsHostBridgeManagement === true || platform === 'linux'
}

export function hostBridgeCanApply(caps: {
  platform?: string | null
  supportsHostMutation?: boolean | null
  supportsHostBridgeManagement?: boolean | null
  supportsManagedBridgeDaemon?: boolean | null
}): boolean {
  if (linuxBridgeCanApply(caps)) return true
  const platform = (caps.platform || '').toLowerCase()
  return (
    (platform === 'macos' || platform === 'darwin')
    && caps.supportsHostMutation === true
    && caps.supportsManagedBridgeDaemon === true
  )
}

/** @deprecated Use hostBridgeCanApply — macOS Apply/Revert uses the same gate. */
export function macosSocketVmnetCanManage(caps: {
  platform?: string | null
  supportsManagedBridgeDaemon?: boolean | null
  supportsHostMutation?: boolean | null
}): boolean {
  const platform = (caps.platform || '').toLowerCase()
  if (platform === 'linux') return false
  if (caps.supportsManagedBridgeDaemon === true) return true
  return platform === 'macos' || platform === 'darwin'
}

export function hostBridgeSetupPending(args: {
  supportsBridgedNetworking: boolean
  hasBridgedNetwork: boolean
  hostReady: boolean | undefined
}): boolean {
  if (!args.supportsBridgedNetworking) return false
  if (args.hasBridgedNetwork) return false
  if (args.hostReady === true) return false
  return true
}
