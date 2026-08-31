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
