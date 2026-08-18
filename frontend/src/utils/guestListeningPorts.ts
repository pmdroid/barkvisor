/** Guest TCP LISTEN display (PAS-225). Loopback is internal and never a URL. */

import type { GuestListeningPort } from '../api/types'
import { guestServiceHref } from './guestHome'

export function isLoopbackAddress(address: string): boolean {
  const host = normalizeAddress(address)
  return host === 'localhost' || host === '::1' || host.startsWith('127.')
}

export function isWildcardAddress(address: string): boolean {
  const host = normalizeAddress(address)
  return host === '0.0.0.0' || host === '*' || host === '::' || host === ''
}

export function guestListeningPortHref(
  port: GuestListeningPort,
  guestIps: string[],
): string | null {
  if (port.scope === 'internal' || isLoopbackAddress(port.address)) return null
  if (!isHttpLike(port)) return null
  const host = isWildcardAddress(port.address) ? guestIps[0] : port.address
  if (!host || isLoopbackAddress(host)) return null
  return guestServiceHref(host, port.port)
}

export function guestListeningPortAccessLabel(port: GuestListeningPort): string {
  if (port.scope === 'internal' || isLoopbackAddress(port.address)) return 'Internal'
  return port.address
}

function isHttpLike(port: GuestListeningPort): boolean {
  return port.label === 'HTTP' || port.label === 'HTTPS' || port.label === 'Dev'
}

function normalizeAddress(address: string): string {
  let host = address.trim()
  if (host.startsWith('[') && host.endsWith(']')) {
    host = host.slice(1, -1)
  }
  return host.toLowerCase()
}
