import type { BridgeInfo, HostBridgeReadiness, HostInterface } from '../api/types'

export type HostInterfaceRole = 'uplink' | 'bridge' | 'loopback' | 'tailscale' | 'external'

export function inferInterfaceRole(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
): HostInterfaceRole {
  const name = iface.name.toLowerCase()
  if (name === 'lo' || name === 'lo0') return 'loopback'
  if (readiness?.bridges.some((bridge) => bridge.name === iface.name)) return 'bridge'
  if (name.startsWith('br') || name.startsWith('bridge')) return 'bridge'
  if (readiness?.defaultRouteInterface === iface.name) return 'uplink'
  if (name.startsWith('utun') || name.includes('tailscale')) return 'tailscale'
  if (name.startsWith('docker') || name.startsWith('veth') || name.startsWith('virbr')) return 'external'
  return 'external'
}

export function interfaceRoleLabel(role: HostInterfaceRole): string {
  switch (role) {
    case 'uplink':
      return 'Uplink'
    case 'bridge':
      return 'Bridge'
    case 'loopback':
      return 'Loopback'
    case 'tailscale':
      return 'Tailscale'
    default:
      return 'External'
  }
}

export function interfaceRoleBadgeClass(role: HostInterfaceRole): string {
  switch (role) {
    case 'uplink':
      return 'badge-green'
    case 'bridge':
      return 'badge-accent'
    default:
      return 'badge-gray'
  }
}

export function formatInterfaceAddressSummary(iface: HostInterface): string {
  const parts: string[] = []
  if (iface.dhcpEnabled) {
    const dhcpAddr = iface.addresses?.find((row) => row.source === 'dhcp')
      ?? iface.addresses?.find((row) => row.primary)
    const ip = dhcpAddr?.cidr?.split('/')[0] || iface.ipAddress
    parts.push(ip ? `DHCP ${ip}` : 'DHCP')
  }
  for (const row of iface.addresses ?? []) {
    if (row.source === 'dhcp') continue
    if (row.cidr) parts.push(row.cidr)
  }
  if (parts.length === 0 && iface.ipAddress) return iface.ipAddress
  return parts.length ? parts.join(' + ') : '—'
}

export function interfaceBridgeColumn(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
  bridgeInfo?: BridgeInfo,
  mode?: string,
): string {
  if (mode === 'macos-guide') {
    if (bridgeInfo?.status === 'active' || bridgeInfo?.status === 'installed') return 'socket_vmnet'
    const enslaved = readiness?.bridges.flatMap((bridge) => bridge.enslaved) ?? []
    if (enslaved.includes(iface.name)) return 'enslaved'
    return '—'
  }
  const master = readiness?.bridges.find((bridge) => bridge.name === iface.name)
  if (master) {
    return master.enslaved.length ? `master (${master.enslaved.join(', ')})` : 'master'
  }
  const parent = readiness?.bridges.find((bridge) => bridge.enslaved.includes(iface.name))
  if (parent) return `→ ${parent.name}`
  if (iface.bridgeStatus === 'active') return 'active'
  if (iface.bridgeStatus === 'installed') return 'installed'
  return '—'
}

export function interfaceRouteColumn(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
): string {
  if (readiness?.defaultRouteInterface === iface.name) return 'default'
  return '—'
}

/** Apply/Revert stays on the interface that owns bridge config (uplink on Mac, uplink or br0 on Linux). */
export function interfaceOwnsBridgeApply(
  role: HostInterfaceRole,
  iface: HostInterface,
  readiness: HostBridgeReadiness | null | undefined,
  mode: string,
): boolean {
  if (role === 'external' || role === 'loopback' || role === 'tailscale') return false
  if (mode === 'macos-guide') return role === 'uplink'
  if (role === 'bridge') return true
  if (role === 'uplink') {
    const enslaved = readiness?.bridges.some((bridge) => bridge.enslaved.includes(iface.name))
    if (enslaved) return false
    return true
  }
  return false
}

export function interfaceOwnsAddressApply(
  role: HostInterfaceRole,
  _iface: HostInterface,
  _readiness: HostBridgeReadiness | null | undefined,
  _mode: string,
): boolean {
  return role === 'bridge'
}

export function addressApplyTargets(
  iface: HostInterface,
  readiness: HostBridgeReadiness | null | undefined,
  _mode: string,
): { nic: string; bridge: string } {
  const mapped = readiness?.bridges.find((bridge) => bridge.name === iface.name)?.enslaved[0]
  if (mapped) return { nic: mapped, bridge: iface.name }
  return { nic: iface.name, bridge: iface.name }
}

export function overlayBridgeAddresses(
  iface: HostInterface,
  peers: HostInterface[],
  readiness?: HostBridgeReadiness | null,
): HostInterface {
  if (inferInterfaceRole(iface, readiness) !== 'bridge') return iface
  if (iface.dhcpEnabled || iface.ipAddress || (iface.addresses?.length ?? 0) > 0) return iface
  const uplinkName = readiness?.bridges.find((bridge) => bridge.name === iface.name)?.enslaved[0]
  if (!uplinkName) return iface
  const uplink = peers.find((peer) => peer.name === uplinkName)
  if (!uplink) return iface
  return {
    ...iface,
    ipAddress: uplink.ipAddress,
    addresses: uplink.addresses,
    dhcpEnabled: uplink.dhcpEnabled,
    gateway: uplink.gateway,
    dns: uplink.dns,
  }
}

export function interfaceAddressColumn(
  iface: HostInterface,
  peers: HostInterface[],
  readiness?: HostBridgeReadiness | null,
): string {
  if (readiness?.bridges.some((bridge) => bridge.enslaved.includes(iface.name))) return '—'
  return formatInterfaceAddressSummary(overlayBridgeAddresses(iface, peers, readiness))
}

export function interfaceBridgeFieldsReadOnly(role: HostInterfaceRole): boolean {
  return role === 'external' || role === 'loopback' || role === 'tailscale'
}

/** Read-only bridge role copy for the interface drawer (#431). */
export function interfaceBridgeRoleDetail(
  role: HostInterfaceRole,
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
  mode?: string,
): string {
  switch (role) {
    case 'uplink': {
      if (mode === 'macos-guide') return 'Uplink · socket_vmnet'
      const parent = readiness?.bridges.find((bridge) => bridge.enslaved.includes(iface.name))
      if (parent) return `Uplink · enslaved to ${parent.name}`
      return 'Uplink · use as bridge uplink'
    }
    case 'bridge': {
      const master = readiness?.bridges.find((bridge) => bridge.name === iface.name)
      if (master?.enslaved.length) return `Bridge · master (${master.enslaved.join(', ')})`
      return 'Bridge · master'
    }
    case 'tailscale':
      return 'Tailscale · external (read-only)'
    case 'loopback':
      return 'Loopback · read-only'
    default:
      return 'External · read-only'
  }
}

/** Pending-bridge rows deep-link to uplink or br0 on the Host interfaces tab. */
export function bridgeSetupInterfaceKey(
  hostId: string,
  readiness: HostBridgeReadiness | null | undefined,
  mode: string,
): string | null {
  if (!readiness) return null
  if (mode === 'macos-guide') {
    const uplink = readiness.defaultRouteInterface
    return uplink ? `${hostId}:${uplink}` : null
  }
  const suggested = readiness.suggestedBridge || 'br0'
  const existing = readiness.bridges.find((bridge) => bridge.name === suggested)
    ?? readiness.bridges[0]
  if (existing) return `${hostId}:${existing.name}`
  const uplink = readiness.defaultRouteInterface
  return uplink ? `${hostId}:${uplink}` : null
}

export function bridgedPickerInterfaces(
  ifaces: HostInterface[],
  readiness?: HostBridgeReadiness | null,
  selected?: string,
): HostInterface[] {
  const bridges = ifaces.filter((iface) => inferInterfaceRole(iface, readiness) === 'bridge')
  if (bridges.length === 0) return ifaces
  if (selected && !bridges.some((iface) => iface.name === selected)) {
    const current = ifaces.find((iface) => iface.name === selected)
    if (current) return [current, ...bridges]
  }
  return bridges
}

export function pendingCommitMatchesInterface(
  pending: { target: string; nic: string },
  ifaceName: string,
  mode: string,
): boolean {
  if (mode === 'macos-guide') return pending.target === ifaceName
  return pending.target === ifaceName || pending.nic === ifaceName
}

export function hostBridgeActionPath(
  base: string,
  nic: string,
  mode: string,
  target?: string | null,
): string {
  if (mode === 'macos-guide') {
    return `${base}/${encodeURIComponent(nic)}`
  }
  return `${base}/${encodeURIComponent(target || nic)}`
}
