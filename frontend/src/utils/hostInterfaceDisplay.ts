import type { BridgeInfo, HostBridgeReadiness, HostInterface, HostInterfaceAddress } from '../api/types'

export type HostInterfaceRole = 'uplink' | 'bridge' | 'loopback' | 'tailscale' | 'external'

export function interfaceEnslavedToBridge(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
): string | null {
  if (iface.bridgeMaster) return iface.bridgeMaster
  const parent = readiness?.bridges.find((bridge) => bridge.enslaved.includes(iface.name))
  return parent?.name ?? null
}

function interfaceHasIPv4(iface: HostInterface): boolean {
  if (iface.addresses?.some((row) => row.cidr)) return true
  return Boolean(iface.ipAddress)
}

function addressSourceLabel(source: HostInterfaceAddress['source'], primary?: boolean): string {
  if (source === 'dhcp') return 'DHCP'
  if (source === 'alias') return 'extra'
  return primary ? 'primary' : 'static'
}

export function formatInterfaceLinkSummary(iface: HostInterface): string {
  const oper = iface.operState?.toLowerCase()
  const carrier = iface.carrier
  if (oper === 'up') {
    if (carrier === true) return 'Up · plugged'
    if (carrier === false) return 'Up · no cable'
    return 'Up'
  }
  if (oper === 'down') {
    if (carrier === false) return 'Down · unplugged'
    return 'Down'
  }
  if (oper === 'notpresent') return 'Not present'
  if (oper === 'lowerlayerdown') return 'No link'
  if (oper === 'dormant') return 'Dormant'
  if (oper === 'unknown') return 'Unknown'
  return oper ?? '—'
}

export function bridgeMasterInterface(
  masterName: string,
  allIfaces: HostInterface[],
): HostInterface | null {
  return allIfaces.find((row) => row.name === masterName) ?? null
}

/** Linux bridged: show L3 from br0 on enslaved ports; br0 row points at members. */
export function effectiveInterfaceForDisplay(
  iface: HostInterface,
  allIfaces: HostInterface[],
  readiness?: HostBridgeReadiness | null,
  mode?: string,
): HostInterface {
  if (mode !== 'linux-guide') return iface
  const masterName = interfaceEnslavedToBridge(iface, readiness)
  if (!masterName) return iface
  const master = bridgeMasterInterface(masterName, allIfaces)
  if (!master || !interfaceHasIPv4(master)) return iface
  return {
    ...iface,
    ipAddress: master.ipAddress,
    addresses: master.addresses,
    dhcpEnabled: master.dhcpEnabled,
    gateway: master.gateway,
    dns: master.dns,
  }
}

export function formatInterfaceAddressSummary(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
  opts?: { mode?: string; allIfaces?: HostInterface[] },
): string {
  const mode = opts?.mode
  const allIfaces = opts?.allIfaces ?? []
  const role = inferInterfaceRole(iface, readiness, mode)

  if (role === 'bridge') return '—'

  const displayIface = mode === 'linux-guide'
    ? effectiveInterfaceForDisplay(iface, allIfaces, readiness, mode)
    : iface
  const enslaved = interfaceEnslavedToBridge(iface, readiness)
  if (enslaved && !interfaceHasIPv4(displayIface)) {
    return '—'
  }
  const parts: string[] = []
  if (displayIface.dhcpEnabled) {
    const dhcpAddr = displayIface.addresses?.find((row) => row.source === 'dhcp')
      ?? displayIface.addresses?.find((row) => row.primary)
    const ip = dhcpAddr?.cidr?.split('/')[0] || displayIface.ipAddress
    parts.push(ip ? `DHCP ${ip}` : 'DHCP')
  }
  for (const row of displayIface.addresses ?? []) {
    if (row.source === 'dhcp') continue
    if (!row.cidr) continue
    const tag = addressSourceLabel(row.source, row.primary)
    parts.push(tag === 'primary' || tag === 'static' ? row.cidr : `${row.cidr} (${tag})`)
  }
  if (parts.length === 0 && displayIface.ipAddress) return displayIface.ipAddress
  return parts.length ? parts.join(' + ') : '—'
}

export function inferInterfaceRole(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
  mode?: string,
): HostInterfaceRole {
  const name = iface.name.toLowerCase()
  if (name === 'lo' || name === 'lo0') return 'loopback'
  // Linux readiness.bridges lists kernel masters (br0). macOS lists socket_vmnet uplinks (en0).
  if (
    mode !== 'macos-guide'
    && readiness?.bridges.some((bridge) => bridge.name === iface.name)
  ) {
    return 'bridge'
  }
  if (name.startsWith('br') || name.startsWith('bridge')) return 'bridge'
  if (interfaceEnslavedToBridge(iface, readiness)) return 'uplink'
  if (readiness?.defaultRouteInterface === iface.name) return 'uplink'
  if (name.startsWith('utun') || name.includes('tailscale')) return 'tailscale'
  if (name.startsWith('docker') || name.startsWith('veth') || name.startsWith('virbr')) return 'external'
  if (
    name.startsWith('en') || name.startsWith('eth') || name.startsWith('enp')
    || name.startsWith('ens') || name.startsWith('eno') || name.startsWith('wl')
    || name.startsWith('bond')
  ) {
    return 'uplink'
  }
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

export function interfaceBridgeColumn(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
  bridgeInfo?: BridgeInfo,
  mode?: string,
): string {
  const master = readiness?.bridges.find((bridge) => bridge.name === iface.name)
  if (master) {
    return master.enslaved.length ? master.enslaved.join(', ') : '—'
  }
  const parent = readiness?.bridges.find((bridge) => bridge.enslaved.includes(iface.name))
  if (parent) return `→ ${parent.name}`
  if (mode === 'macos-guide' && (bridgeInfo?.status === 'active' || bridgeInfo?.status === 'installed')) {
    return '—'
  }
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

/** Apply/Revert for bridge setup (Linux br0 / standalone uplink; Mac uplink). */
export function interfaceOwnsBridgeSetupApply(
  role: HostInterfaceRole,
  iface: HostInterface,
  readiness: HostBridgeReadiness | null | undefined,
  mode: string,
): boolean {
  if (role === 'external' || role === 'loopback' || role === 'tailscale') return false
  if (mode === 'macos-guide') return role === 'uplink' || role === 'bridge'
  if (role === 'bridge') return true
  if (role === 'uplink' && !interfaceEnslavedToBridge(iface, readiness)) return true
  return false
}

export function interfaceOwnsAddressApply(
  role: HostInterfaceRole,
  _iface: HostInterface,
  _readiness: HostBridgeReadiness | null | undefined,
  _mode: string,
): boolean {
  return role === 'uplink'
}

export function interfaceOwnsBridgeApply(
  role: HostInterfaceRole,
  iface: HostInterface,
  readiness: HostBridgeReadiness | null | undefined,
  mode: string,
): boolean {
  return interfaceOwnsBridgeSetupApply(role, iface, readiness, mode)
    || interfaceOwnsAddressApply(role, iface, readiness, mode)
}

export function addressApplyTargets(
  iface: HostInterface,
  readiness: HostBridgeReadiness | null | undefined,
  _mode: string,
): { nic: string; bridge: string } {
  const parent = interfaceEnslavedToBridge(iface, readiness)
  if (parent) return { nic: iface.name, bridge: parent }
  const mapped = readiness?.bridges.find((bridge) => bridge.name === iface.name)?.enslaved[0]
  if (mapped) return { nic: mapped, bridge: iface.name }
  return { nic: iface.name, bridge: '' }
}

export function overlayBridgeAddresses(
  iface: HostInterface,
  peers: HostInterface[],
  readiness?: HostBridgeReadiness | null,
): HostInterface {
  const parent = interfaceEnslavedToBridge(iface, readiness)
  if (!parent) return iface
  if (interfaceHasIPv4(iface)) return iface
  const master = peers.find((peer) => peer.name === parent)
  if (!master || !interfaceHasIPv4(master)) return iface
  return {
    ...iface,
    ipAddress: master.ipAddress,
    addresses: master.addresses,
    dhcpEnabled: master.dhcpEnabled,
    gateway: master.gateway,
    dns: master.dns,
  }
}

export function interfaceAddressColumn(
  iface: HostInterface,
  peers: HostInterface[],
  readiness?: HostBridgeReadiness | null,
): string {
  if (inferInterfaceRole(iface, readiness) === 'bridge') return '—'
  return formatInterfaceAddressSummary(
    overlayBridgeAddresses(iface, peers, readiness),
    readiness,
    { allIfaces: peers },
  )
}

export function interfaceBridgeFieldsReadOnly(role: HostInterfaceRole): boolean {
  return role === 'external' || role === 'loopback' || role === 'tailscale'
}

/** L3 fields: on Linux, editable on ports (incl. enslaved); not on br0. */
export function interfaceAddressFieldsReadOnly(
  role: HostInterfaceRole,
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
  mode?: string,
): boolean {
  if (interfaceBridgeFieldsReadOnly(role)) return true
  if (mode === 'linux-guide' && role === 'bridge') return true
  if (mode !== 'linux-guide' && interfaceEnslavedToBridge(iface, readiness)) return true
  return false
}

export function bridgeMemberNames(
  bridgeName: string,
  readiness?: HostBridgeReadiness | null,
): string[] {
  const master = readiness?.bridges.find((bridge) => bridge.name === bridgeName)
  return master?.enslaved ?? []
}

export function existingBridgeForInterfaceApply(
  role: HostInterfaceRole,
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
): string | null {
  if (role === 'bridge') return iface.name
  return interfaceEnslavedToBridge(iface, readiness)
}

/** Uplink NIC sent to POST /api/system/bridges when the drawer targets a bridge master. */
export function resolveBridgeApplyNic(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
): string {
  const master = readiness?.bridges.find((bridge) => bridge.name === iface.name)
  if (master?.enslaved[0]) return master.enslaved[0]
  return iface.name
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

export function pendingCommitBridgeName(
  pending: { target: string; nic: string },
  readiness?: HostBridgeReadiness | null,
): string {
  const parent = readiness?.bridges.find(
    (bridge) =>
      bridge.name === pending.target
      || bridge.enslaved.includes(pending.target)
      || bridge.enslaved.includes(pending.nic),
  )
  return parent?.name ?? pending.target
}

export function pendingCommitMatchesInterface(
  pending: { target: string; nic: string },
  ifaceName: string,
  _mode: string,
  readiness?: HostBridgeReadiness | null,
): boolean {
  if (pending.nic === ifaceName) return true
  if (pending.target === ifaceName) {
    const isBridgeRow = readiness?.bridges.some((bridge) => bridge.name === ifaceName)
    if (isBridgeRow && pending.nic && pending.nic !== ifaceName) return false
    return true
  }
  return false
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

export function interfaceAssociatedBridge(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
): { name: string; createdBridge: boolean } | null {
  const master = readiness?.bridges.find((bridge) => bridge.name === iface.name)
  if (master) return { name: master.name, createdBridge: master.createdBridge === true }
  const parent = readiness?.bridges.find((bridge) => bridge.enslaved.includes(iface.name))
  if (parent) return { name: parent.name, createdBridge: parent.createdBridge === true }
  return null
}

export function interfaceShowsDelete(
  iface: HostInterface,
  readiness?: HostBridgeReadiness | null,
): boolean {
  return interfaceAssociatedBridge(iface, readiness)?.createdBridge === true
}

export function syntheticMacBridgeIfaces(
  ifaces: HostInterface[],
  readiness: HostBridgeReadiness | null | undefined,
  mode: string,
): HostInterface[] {
  if (mode !== 'macos-guide' || !readiness) return []
  const seen = new Set(ifaces.map((iface) => iface.name))
  const extra: HostInterface[] = []
  for (const bridge of readiness.bridges) {
    if (!bridge.name || seen.has(bridge.name)) continue
    if (!/^br\d+$/.test(bridge.name)) continue
    seen.add(bridge.name)
    extra.push({
      name: bridge.name,
      displayName: bridge.name,
      ipAddress: '',
      managedByBarkvisor: true,
    })
  }
  return extra
}
