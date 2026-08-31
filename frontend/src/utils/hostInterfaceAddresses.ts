import type { HostBridgeAddressApplyEntry, HostBridgeApplyRequest, HostInterface, HostInterfaceAddress } from '../api/types'

export type EditableAddressKind = 'dhcp' | 'static' | 'alias'

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

export function addressesFromInterface(iface?: HostInterface | null): EditableHostAddress[] {
  const rows = iface?.addresses ?? []
  const out: EditableHostAddress[] = []
  if (iface?.dhcpEnabled) {
    out.push({ id: 'dhcp', kind: 'dhcp', cidr: '' })
  }
  for (const row of rows) {
    if (row.source === 'dhcp') continue
    out.push({
      id: row.cidr,
      kind: row.source === 'alias' ? 'alias' : 'static',
      cidr: row.cidr,
    })
  }
  if (out.length === 0 && !iface?.dhcpEnabled) {
    out.push({ id: 'static-new', kind: 'static', cidr: '' })
  }
  return out
}

export function validateAddressList(
  rows: EditableHostAddress[],
  opts?: { onlyUplink?: boolean },
): AddressListValidation {
  const errors: string[] = []
  const warnings: string[] = []
  const hasDHCP = rows.some((r) => r.kind === 'dhcp')
  const staticRows = rows.filter((r) => r.kind !== 'dhcp')
  const cidrs = staticRows.map((r) => r.cidr.trim()).filter(Boolean)

  if (!hasDHCP && cidrs.length === 0) {
    errors.push('Add DHCP or at least one static address.')
  }
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
  if (!hasDHCP && cidrs.length > 0) {
    // gateway validated by caller — static-only needs gateway at apply time
  }
  if (opts?.onlyUplink) {
    warnings.push('This Device has a single uplink. Changing its address can drop SSH and the SPA.')
  }
  return { ok: errors.length === 0, errors, warnings }
}

export function buildAddressApplyEntries(rows: EditableHostAddress[]): HostBridgeAddressApplyEntry[] {
  const entries: HostBridgeAddressApplyEntry[] = []
  for (const row of rows) {
    if (row.kind === 'dhcp') {
      entries.push({ kind: 'dhcp' })
      continue
    }
    const cidr = row.cidr.trim()
    if (!cidr) continue
    entries.push({
      kind: row.kind,
      cidr,
    })
  }
  return entries
}

export function buildHostBridgeApplyBody(input: {
  nic?: string
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
  const hasLegacyStaticOnly = addresses.length === 1
    && addresses[0]?.kind === 'static'
    && addresses[0]?.cidr
  if (hasLegacyStaticOnly) {
    body.addressing = 'static'
    body.address = addresses[0]?.cidr
    const gateway = input.gateway?.trim()
    if (gateway) body.gateway = gateway
  } else if (addresses.some((a) => a.kind === 'dhcp') && addresses.every((a) => a.kind === 'dhcp')) {
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
