import type { HostBridgeReadiness } from '../api/types'
import type { GuestCommandGroup } from './guestAgentInstall'

/** Copyable Linux host-bridge steps (PAS-222). BarkVisor does not run these. */
export function linuxBridgeSetupGroups(ready: HostBridgeReadiness): GuestCommandGroup[] {
  const br = ready.suggestedBridge || 'br0'
  const helper = ready.helperPath || '/usr/lib/qemu/qemu-bridge-helper'
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
      commands: `echo 'allow ${br}' | sudo tee /etc/qemu/bridge.conf`,
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
  helperPath: '/usr/lib/qemu/qemu-bridge-helper',
  helperSetuid: false,
  suggestedBridge: 'br0',
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
