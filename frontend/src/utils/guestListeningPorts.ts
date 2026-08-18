/** Guest TCP LISTEN display (PAS-225). Loopback is internal and never a URL. */

import type { GuestListeningPort, PortForwardRule } from '../api/types'
import { guestServiceHref } from './guestHome'

/** QEMU user-net guest address — not reachable from the operator browser. */
export const slirpGuestIPv4 = '10.0.2.15'

export type GuestListeningPortAccess = {
  isMember: boolean
  /** Bridged/shared guest IPs the operator can open. NAT/isolated stay false. */
  guestIpsReachable: boolean
  portForwards: PortForwardRule[]
}

export function isLoopbackAddress(address: string): boolean {
  const host = normalizeAddress(address)
  return host === 'localhost' || host === '::1' || host.startsWith('127.')
}

export function isWildcardAddress(address: string): boolean {
  const host = normalizeAddress(address)
  return host === '0.0.0.0' || host === '*' || host === '::' || host === ''
}

export function isOperatorReachableGuestAddress(address: string): boolean {
  const host = normalizeAddress(address)
  if (!host || isLoopbackAddress(host) || isWildcardAddress(host)) return false
  return host !== slirpGuestIPv4
}

export function guestListeningPortHref(
  port: GuestListeningPort,
  guestIps: string[],
  access?: GuestListeningPortAccess,
): string | null {
  if (port.scope === 'internal' || isLoopbackAddress(port.address)) return null
  if (!isHttpLike(port)) return null
  const host = operatorReachableHost(port, guestIps, access)
  if (host) return hrefFor(host, port.port, port.label)
  if (access?.isMember) return null
  const hostPort = tcpHostForwardPort(port.port, access?.portForwards ?? [])
  if (hostPort == null) return null
  return hrefFor('127.0.0.1', hostPort, port.label)
}

export function guestListeningPortAccessLabel(port: GuestListeningPort): string {
  if (port.scope === 'internal' || isLoopbackAddress(port.address)) return 'Internal'
  return port.address
}

function isHttpLike(port: GuestListeningPort): boolean {
  return port.label === 'HTTP' || port.label === 'HTTPS' || port.label === 'Dev'
}

function operatorReachableHost(
  port: GuestListeningPort,
  guestIps: string[],
  access: GuestListeningPortAccess | undefined,
): string | undefined {
  if (access && !access.guestIpsReachable) return undefined
  const candidate = isWildcardAddress(port.address)
    ? guestIps.find(isOperatorReachableGuestAddress)
    : port.address
  if (!candidate || !isOperatorReachableGuestAddress(candidate)) return undefined
  return candidate
}

function tcpHostForwardPort(
  guestPort: number,
  forwards: PortForwardRule[],
): number | undefined {
  return forwards.find((pf) => pf.protocol === 'tcp' && pf.guestPort === guestPort)?.hostPort
}

function hrefFor(host: string, port: number, label: string | null): string {
  const href = guestServiceHref(host, port)
  if (label !== 'HTTPS' || href.startsWith('https://')) return href
  return `https://${href.slice('http://'.length)}`
}

function normalizeAddress(address: string): string {
  let host = address.trim()
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.slice(1, -1)
  }
  return host.toLowerCase()
}
