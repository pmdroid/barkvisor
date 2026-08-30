import type { HostBridgeReadiness } from '../api/types'
import type { GuestCommandGroup } from './guestAgentInstall'
import {
  HOST_BRIDGE_ACL_PATH,
  HOST_BRIDGE_HELPER_PATH,
  HOST_BRIDGE_SUGGESTED,
} from './hostBridgeFacts'

/** Linux must not render these. macOS Setup/Start/Stop are #379. Remove stays gone. */
export const BRIDGE_MUTATION_ACTION_KEYS = ['setup', 'start', 'stop', 'remove'] as const
export type BridgeMutationActionKey = (typeof BRIDGE_MUTATION_ACTION_KEYS)[number]
export const MACOS_SOCKET_VMNET_ACTION_KEYS = ['setup', 'start', 'stop'] as const

export const LINUX_BRIDGE_APPLY_SCRIPT = 'linux-bridge-apply.sh'

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
        '# barkvisor:allow-br0',
        `printf '%s\\n%s\\n' '# barkvisor:allow-br0' 'allow ${br}' | sudo tee -a ${HOST_BRIDGE_ACL_PATH}`,
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

export const MACOS_DEVICE_ADDRESS_PLACEHOLDER = 'Ethernet'

export function macosDeviceAddressCommands(service = MACOS_DEVICE_ADDRESS_PLACEHOLDER): string {
  const quoted = JSON.stringify(service)
  return [
    '# Host address on this Device (DHCP or static). Guest static IP is separate.',
    `sudo networksetup -setdhcp ${quoted}`,
    `sudo networksetup -setmanual ${quoted} 192.168.1.10 255.255.255.0 192.168.1.1`,
  ].join('\n')
}

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
    label: 'Device address',
    commands: macosDeviceAddressCommands(),
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

/** Equivalent apply commands. Addressing stays on the script, not the SPA. */
export function linuxBridgeApplyCommands(ready: HostBridgeReadiness): string[] {
  const br = ready.suggestedBridge || HOST_BRIDGE_SUGGESTED
  const nic = ready.defaultRouteInterface || '<wired-uplink>'
  return [
    `# Persist ${br} with NetworkManager, netplan, or systemd-networkd. Refuse Wi-Fi.`,
    `# Host address on ${br} is this Device (DHCP or static). Guest static IP is separate.`,
    `sudo ${LINUX_BRIDGE_APPLY_SCRIPT} --apply --nic ${nic} --dhcp`,
    '# Rollback is a host timer (netplan try). Do not Confirm in the browser after the uplink dies.',
  ]
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

/** Root Device daemon may Setup/Start/Stop socket_vmnet on a Mac Device. */
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
