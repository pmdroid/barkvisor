import type { HostBridgeAddressApplyEntry, HostBridgeApplyRequest, HostInterface, HostInterfaceAddress } from '../api/types'

/** UI row kinds — apply layer still uses dhcp / static / alias. */
export type EditableAddressKind = 'dhcp' | 'primary' | 'additional'

export interface EditableHostAddress {
  id: string
  kind: EditableAddressKind
  cidr: string
}

export interface AddressListValidation {
  ok: boolean
  errors: string[]
  warnings: string[]
}

const CIDR_RE = /^(\d{1,3}\.){3}\d{1,3}\/\d{1,2}$/

export function isValidCIDR(value: string): boolean {
  const trimmed = value.trim()
  if (!CIDR_RE.test(trimmed)) return false
  const [ip, prefixRaw] = trimmed.split('/')
  const prefix = Number(prefixRaw)
  if (!Number.isInteger(prefix) || prefix < 1 || prefix > 32) return false
  return ip.split('.').every((octet) => {
    const n = Number(octet)
    return Number.isInteger(n) && n >= 0 && n <= 255
  })
}

function isIpRow(kind: EditableAddressKind): boolean {
  return kind === 'primary' || kind === 'additional'
}

function rowLabel(kind: EditableAddressKind, dhcpEnabled: boolean): string {
  if (kind === 'primary') return 'Primary address'
  if (kind === 'additional') return dhcpEnabled ? 'Additional address' : 'Additional address'
  return 'DHCP'
}

export function addressRowLabel(kind: EditableAddressKind, dhcpEnabled: boolean): string {
  return rowLabel(kind, dhcpEnabled)
}

/** Map API/discovered addresses into editable drawer rows. */
export function addressesFromInterface(iface?: HostInterface | null): EditableHostAddress[] {
  const configRows = iface?.addresses ?? []
  const out: EditableHostAddress[] = []

  if (iface?.dhcpEnabled) {
    const dhcpCidr = configRows.find((row) => row.source === 'dhcp')?.cidr
      || (iface.ipAddress?.includes('/') ? iface.ipAddress : iface.ipAddress ? `${iface.ipAddress}/32` : '')
    out.push({ id: 'dhcp', kind: 'dhcp', cidr: dhcpCidr })
    for (const row of configRows) {
      if (row.source === 'dhcp') continue
      out.push({
        id: addressRowId(row.cidr, out.length),
        kind: 'additional',
        cidr: row.cidr,
      })
    }
    return out
  }

  let primarySet = false
  for (const row of configRows) {
    if (row.source === 'dhcp') continue
    if (!primarySet) {
      out.push({ id: 'primary', kind: 'primary', cidr: row.cidr })
      primarySet = true
    } else {
      out.push({
        id: addressRowId(row.cidr, out.length),
        kind: 'additional',
        cidr: row.cidr,
      })
    }
  }
  if (!primarySet) {
    out.push({ id: 'primary', kind: 'primary', cidr: iface?.ipAddress?.includes('/')
      ? iface.ipAddress
      : iface?.ipAddress
        ? `${iface.ipAddress}/32`
        : '' })
  }
  return out
}

function addressRowId(cidr: string, index: number): string {
  return cidr ? `addr-${cidr}` : `addr-new-${index}`
}

export function validateAddressList(
  rows: EditableHostAddress[],
  opts?: { onlyUplink?: boolean; gateway?: string },
): AddressListValidation {
  const errors: string[] = []
  const warnings: string[] = []
  const hasDHCP = rows.some((r) => r.kind === 'dhcp')
  const primary = rows.find((r) => r.kind === 'primary')
  const additional = rows.filter((r) => r.kind === 'additional')

  if (!hasDHCP) {
    if (!primary?.cidr?.trim()) {
      errors.push('Primary address is required when DHCP is off (e.g. 192.168.1.10/24).')
    }
    if (!opts?.gateway?.trim()) {
      errors.push('Gateway is required when using a static primary address.')
    }
  }

  const cidrs = [
    ...(hasDHCP ? [] : [primary?.cidr?.trim() ?? '']),
    ...additional.map((r) => r.cidr.trim()),
  ].filter(Boolean)

  const seen = new Set<string>()
  for (const cidr of cidrs) {
    if (!isValidCIDR(cidr)) {
      errors.push(`Invalid CIDR: ${cidr || '(empty)'}`)
      continue
    }
    if (seen.has(cidr)) {
      errors.push(`Duplicate address ${cidr}`)
    }
    seen.add(cidr)
  }

  if (opts?.onlyUplink) {
    warnings.push('This Device has a single uplink. Changing its address can drop SSH and the SPA.')
  }
  return { ok: errors.length === 0, errors, warnings }
}

/** Normalize UI rows to backend apply entries (static + alias semantics). */
export function buildAddressApplyEntries(rows: EditableHostAddress[]): HostBridgeAddressApplyEntry[] {
  const entries: HostBridgeAddressApplyEntry[] = []
  const hasDHCP = rows.some((r) => r.kind === 'dhcp')
  if (hasDHCP) {
    entries.push({ kind: 'dhcp' })
  }
  const ipRows = rows.filter((r) => isIpRow(r.kind))
  for (const [index, row] of ipRows.entries()) {
    const cidr = row.cidr.trim()
    if (!cidr) continue
    if (!hasDHCP && index === 0) {
      entries.push({ kind: 'static', cidr })
    } else {
      entries.push({ kind: 'alias', cidr })
    }
  }
  return entries
}

export function buildHostBridgeApplyBody(input: {
  nic?: string
  bridge?: string
  confirm?: boolean
  action?: HostBridgeApplyRequest['action']
  rows: EditableHostAddress[]
  gateway?: string
  dns?: string
}): HostBridgeApplyRequest {
  const addresses = buildAddressApplyEntries(input.rows)
  const body: HostBridgeApplyRequest = {
    interface: input.nic,
    action: input.action ?? 'apply',
    confirm: input.confirm ?? false,
    addresses,
  }
  const hasDHCP = input.rows.some((r) => r.kind === 'dhcp')
  const bridge = input.bridge?.trim()
  if (bridge) body.bridge = bridge
  const hasLegacyStaticOnly = addresses.length === 1
    && addresses[0]?.kind === 'static'
    && addresses[0]?.cidr
  if (hasLegacyStaticOnly) {
    body.addressing = 'static'
    body.address = addresses[0]?.cidr
    const gateway = input.gateway?.trim()
    if (gateway) body.gateway = gateway
  } else if (hasDHCP && addresses.every((a) => a.kind === 'dhcp')) {
    body.addressing = 'dhcp'
  }
  const gateway = input.gateway?.trim()
  if (gateway) body.gateway = gateway
  const dns = input.dns?.split(/[,\s]+/).map((s) => s.trim()).filter(Boolean) ?? []
  if (dns.length) body.dns = dns
  return body
}

export function summarizeLiveAddresses(rows: HostInterfaceAddress[] | undefined): string {
  if (!rows?.length) return '—'
  return rows.map((r) => {
    const tag = r.source === 'dhcp' ? 'DHCP' : r.source === 'alias' ? 'alias' : 'static'
    return `${r.cidr} (${tag})`
  }).join(', ')
}

/** Ensure static mode has a primary row; dhcp mode drops primary. */
export function applyDhcpToggle(rows: EditableHostAddress[], enabled: boolean): EditableHostAddress[] {
  const withoutDhcp = rows.filter((r) => r.kind !== 'dhcp')
  const dhcpRow = rows.find((r) => r.kind === 'dhcp')
  const extras = withoutDhcp.filter((r) => r.kind === 'additional')
  if (enabled) {
    const primary = withoutDhcp.find((r) => r.kind === 'primary')
    return [
      { id: 'dhcp', kind: 'dhcp', cidr: primary?.cidr.trim() || dhcpRow?.cidr?.trim() || '' },
      ...extras,
    ]
  }
  const primary = withoutDhcp.find((r) => r.kind === 'primary')
    ?? { id: 'primary', kind: 'primary' as const, cidr: dhcpRow?.cidr?.trim() || '' }
  return [primary, ...extras]
}

export function addAdditionalAddress(rows: EditableHostAddress[]): EditableHostAddress[] {
  return [
    ...rows,
    { id: `addr-new-${Date.now()}`, kind: 'additional', cidr: '' },
  ]
}
