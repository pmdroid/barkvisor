/** Guest TCP LISTEN display (PAS-225) and This Device NAT hostfwd suggest (PAS-228).
 *  Loopback is internal and never a URL. */

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

export const publishedGuestPorts = new Set([
  22, 80, 443,
  3000, 3001, 4173, 4200, 5000, 5173, 5174,
  8000, 8080, 8081, 8443, 8888,
  3306, 5432, 6379, 27017,
  3389, 5900,
])

export function isPublishedGuestPort(port: Pick<GuestListeningPort, 'port'>): boolean {
  return publishedGuestPorts.has(port.port)
}

export function guestListeningPortHref(
  port: GuestListeningPort,
  guestIps: string[],
  access?: GuestListeningPortAccess,
): string | null {
  if (port.scope === 'internal' || isLoopbackAddress(port.address)) return null
  if (!isHttpLike(port)) return null
  const host = operatorReachableHost(port, guestIps, access)
  if (host) return hrefFor(host, port.port, port)
  if (access?.isMember) return null
  const hostPort = tcpHostForwardPort(port.port, access?.portForwards ?? [])
  if (hostPort == null) return null
  return hrefFor('127.0.0.1', hostPort, port)
}

export function guestListeningPortAccessLabel(port: GuestListeningPort): string {
  if (port.scope === 'internal' || isLoopbackAddress(port.address)) return 'Internal'
  return port.address
}

function isHttpLike(port: GuestListeningPort): boolean {
  if (port.scheme === 'http' || port.scheme === 'https') return true
  if (port.scheme === null) return false
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
  return matchingTcpHostfwd(guestPort, forwards)?.hostPort
}

/** Implicit NAT (missing networkId) and explicit NAT allow `hostfwd`. */
export function natHostfwdAllowsMode(mode: string | null | undefined): boolean {
  return !mode || mode === 'nat'
}

/** Host TCP ports claimed by NAT / implicit-NAT Workloads (PAS-64 registry). */
export function claimedNatTcpHostPorts(
  vms: Array<{ networkId: string | null; portForwards: PortForwardRule[] | null }>,
  networks: Array<{ id: string; mode: string }>,
): number[] {
  const modeById = new Map(networks.map((n) => [n.id, n.mode]))
  const ports: number[] = []
  for (const vm of vms) {
    const mode = vm.networkId ? modeById.get(vm.networkId) : undefined
    if (mode && !natHostfwdAllowsMode(mode)) continue
    for (const pf of vm.portForwards ?? []) {
      if (pf.protocol === 'tcp') ports.push(pf.hostPort)
    }
  }
  return ports
}

export function matchingTcpHostfwd(
  guestPort: number,
  forwards: PortForwardRule[],
): PortForwardRule | undefined {
  return forwards.find((pf) => pf.protocol === 'tcp' && pf.guestPort === guestPort)
}

/** Guest port if unused, otherwise the next unused host TCP port. */
export function nextFreeHostPort(
  preferred: number,
  occupied: Iterable<number>,
): number | null {
  const taken = new Set(occupied)
  const start = Math.min(Math.max(Math.trunc(preferred), 1), 65535)
  for (let port = start; port <= 65535; port++) {
    if (!taken.has(port)) return port
  }
  return null
}

export type SuggestPublishNatHostfwdAccess = {
  isMember: boolean
  /** Bridged / isolated hide the control. Null is implicit NAT. */
  networkMode: string | null | undefined
  portForwards: PortForwardRule[]
  occupiedHostPorts: Iterable<number>
}

/** This Device NAT only. Loopback and member NAT stay non-clickable. */
export function suggestPublishNatHostfwd(
  port: GuestListeningPort,
  access: SuggestPublishNatHostfwdAccess,
): PortForwardRule | null {
  if (access.isMember) return null
  if (!natHostfwdAllowsMode(access.networkMode)) return null
  if (port.proto.toLowerCase() !== 'tcp') return null
  if (port.scope === 'internal' || isLoopbackAddress(port.address)) return null
  if (!isPublishedGuestPort(port)) return null
  if (matchingTcpHostfwd(port.port, access.portForwards)) return null
  const hostPort = nextFreeHostPort(port.port, access.occupiedHostPorts)
  if (hostPort == null) return null
  return { protocol: 'tcp', hostPort, guestPort: port.port }
}

function hrefFor(host: string, port: number, item: GuestListeningPort): string {
  const href = guestServiceHref(host, port)
  const https = item.scheme === 'https' || item.label === 'HTTPS'
  if (!https || href.startsWith('https://')) return href
  return `https://${href.slice('http://'.length)}`
}

function normalizeAddress(address: string): string {
  let host = address.trim()
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.slice(1, -1)
  }
  return host.toLowerCase()
}
