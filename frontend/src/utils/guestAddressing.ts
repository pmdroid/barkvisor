import type { GuestAddressing, Network } from '../api/types'

export const GUEST_ADDRESSING_DHCP = 'dhcp'
export const GUEST_ADDRESSING_STATIC = 'static'

export function isBridgedNetwork(network: Network | null | undefined): boolean {
  return network?.mode === 'bridged'
}

export function cloudInitApplies(input: {
  mode?: 'iso' | 'cloud'
  cloudInitPath?: string | null
}): boolean {
  if (input.cloudInitPath) return true
  return input.mode === 'cloud'
}

export function macReservationCopy(input: {
  bridged: boolean
  cloudInit: boolean
}): string {
  if (input.bridged && input.cloudInit) {
    return 'Paste this MAC into your router for a DHCP reservation. Or set a static IPv4 here — cloud-init writes it on next boot.'
  }
  return 'Set the address in the guest or on the router. BarkVisor did not configure the OS.'
}

export function staticRefusedCopy(input: {
  bridged: boolean
  cloudInit: boolean
}): string | null {
  if (input.bridged && input.cloudInit) return null
  if (!input.bridged) {
    return 'Static IPv4 is only for bridged Workloads. NAT uses port forwards.'
  }
  return 'Static IPv4 needs a cloud-init image. Installer ISOs: set it in the guest or on the router.'
}

const ipv4 =
  /^(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/

export function validateGuestAddressing(addr: GuestAddressing): string | null {
  if (addr.mode === GUEST_ADDRESSING_DHCP) return null
  if (addr.mode !== GUEST_ADDRESSING_STATIC) return 'Addressing must be DHCP or static.'
  if (!addr.ipv4 || !ipv4.test(addr.ipv4)) return 'Enter a valid IPv4 address.'
  const prefix = addr.prefixLength
  if (prefix == null || prefix < 1 || prefix > 32) return 'Prefix length must be 1–32.'
  if (!addr.gateway || !ipv4.test(addr.gateway)) return 'Enter a valid gateway IPv4.'
  for (const dns of addr.nameservers ?? []) {
    if (dns && !ipv4.test(dns)) return 'Each DNS server must be an IPv4 address.'
  }
  return null
}

export function payloadGuestAddressing(input: {
  bridged: boolean
  cloudInit: boolean
  mode: 'dhcp' | 'static'
  ipv4: string
  prefixLength: number | null
  gateway: string
  nameservers: string
}): GuestAddressing | undefined {
  if (!input.bridged || !input.cloudInit) return undefined
  if (input.mode === GUEST_ADDRESSING_DHCP) return undefined
  const dns = input.nameservers
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean)
  return {
    mode: GUEST_ADDRESSING_STATIC,
    ipv4: input.ipv4.trim(),
    prefixLength: input.prefixLength ?? undefined,
    gateway: input.gateway.trim(),
    nameservers: dns.length ? dns : undefined,
  }
}
