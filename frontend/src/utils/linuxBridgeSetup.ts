import type { HostBridgeReadiness } from '../api/types'
import type { GuestCommandGroup } from './guestAgentInstall'
import {
  HOST_BRIDGE_ACL_PATH,
  HOST_BRIDGE_HELPER_PATH,
  HOST_BRIDGE_SUGGESTED,
} from './hostBridgeFacts'

/** Host-mutating action keys the Networks UI must never render. */
export const BRIDGE_MUTATION_ACTION_KEYS = ['setup', 'start', 'stop', 'remove'] as const
export type BridgeMutationActionKey = (typeof BRIDGE_MUTATION_ACTION_KEYS)[number]

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

/** Matches SocketVmnetDiscovery.installHint with one command per line. */
export const SOCKET_VMNET_INSTALL_COMMANDS = [
  'brew install socket_vmnet',
  'sudo brew services start socket_vmnet',
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
      commands: [
        `sudo ip link add name ${br} type bridge`,
        `sudo ip link set ${br} up`,
        `# Then put the host IP/DHCP on ${br}, not the physical NIC.`,
        `# sudo ip link set <nic> master ${br}`,
      ].join('\n'),
    })
  }

  if (ready.aclAllowsSuggested !== true) {
    groups.push({
      id: 'allow-acl',
      label: `Allow ${br} in qemu-bridge.conf`,
      commands: `echo 'allow ${br}' | sudo tee ${HOST_BRIDGE_ACL_PATH}`,
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

export function linuxBridgeStatusSummary(ready: HostBridgeReadiness): string {
  if (ready.ready) {
    const names = ready.bridges.map((b) => b.name).join(', ')
    return `This Device is ready for Bridged networks (${names || ready.suggestedBridge}).`
  }
  if (ready.onlyUplink) {
    return 'This Device has a single uplink. Do not enslave it into a bridge (you can lose SSH). Prefer NAT, or add another NIC first.'
  }
  return 'This Device is not ready for Bridged networks yet. Run the steps below, then Re-check.'
}

/** Copyable macOS socket_vmnet steps. Prefer remediations from HostBridgeFacts. */
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
  if (ready?.ready) return []
  return [
    {
      id: 'homebrew-socket-vmnet',
      label: 'Install and start socket_vmnet',
      commands: SOCKET_VMNET_INSTALL_COMMANDS,
    },
  ]
}

export function macosSocketVmnetStatusSummary(
  ready?: HostBridgeReadiness | null,
): string {
  if (!ready) {
    return 'Could not read socket_vmnet status on this Device. Run the steps below, then Re-check.'
  }
  if (ready.ready) {
    const names = ready.bridges.map((b) => b.name).join(', ')
    return `This Device is ready for Bridged networks (${names || 'socket_vmnet'}).`
  }
  return 'This Device is not ready for Bridged networks yet. Install socket_vmnet with Homebrew, then Re-check.'
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
