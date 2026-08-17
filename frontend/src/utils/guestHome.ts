/** Home guest-info (PAS-201).
 *  Workloads list + member detail share this. Fetch the existing guest-info
 *  route through the Home proxy. Unreachable members stay empty (—). */

import type { GuestInfo, PortForwardRule } from '../api/types'
import {
  canFetchDeviceWorkloads,
  deviceGuestInfoPath,
  type DeviceApiTarget,
} from './homeDeviceApi'

export { deviceGuestInfoPath }

export function canFetchGuestInfo(device: DeviceApiTarget): boolean {
  return canFetchDeviceWorkloads(device)
}

/** Null when the Device is unreachable or the Workload is not running. */
export function guestInfoFetchPath(
  device: DeviceApiTarget | null | undefined,
  vmId: string,
  vmState: string | undefined,
): string | null {
  if (!device || !canFetchGuestInfo(device)) return null
  if (vmState !== 'running') return null
  return deviceGuestInfoPath(device, vmId)
}

/** Cached guest-info is only valid while the Workload is running. */
export function guestInfoIfRunning(
  guest: GuestInfo | null | undefined,
  vmState: string | undefined,
): GuestInfo | null {
  if (vmState !== 'running') return null
  return guest ?? null
}

export function guestOsLabel(
  guest: GuestInfo | null | undefined,
  vmType: string,
  live = true,
): string {
  if (!live) return '—'
  if (guest?.osName) {
    return guest.osVersion ? `${guest.osName} ${guest.osVersion}` : guest.osName
  }
  return vmType.startsWith('windows') ? 'Windows' : 'Linux'
}

export function guestPrimaryIp(guest: GuestInfo | null | undefined): string | null {
  if (!guest?.available || !guest.ipAddresses?.length) return null
  return guest.ipAddresses[0]
}

function hostForUrl(ip: string): string {
  return ip.includes(':') ? `[${ip}]` : ip
}

export function guestServiceHref(ip: string, guestPort: number): string {
  const proto = guestPort === 443 || guestPort === 9443 ? 'https' : 'http'
  const host = hostForUrl(ip)
  const port = guestPort === 80 || guestPort === 443 ? '' : `:${guestPort}`
  return `${proto}://${host}${port}`
}

export function guestServiceLabel(ip: string, guestPort: number): string {
  const host = hostForUrl(ip)
  return guestPort === 80 || guestPort === 443 ? host : `${host}:${guestPort}`
}

export type GuestPortLink = {
  label: string
  copyText: string
  href?: string
}

export type GuestIpPortsView =
  | { kind: 'empty' }
  | { kind: 'bridged-ip'; ip: string; links: GuestPortLink[] }
  | { kind: 'nat-localhost'; hostPorts: number[] }
  | { kind: 'port-map'; labels: string[] }

/** Member rows never use localhost — that address is the member Device, not this browser. */
export function guestIpPortsView(input: {
  reachable: boolean
  isMember: boolean
  isLocalNat: boolean
  guest: GuestInfo | null | undefined
  portForwards: PortForwardRule[]
}): GuestIpPortsView {
  if (input.isMember && !input.reachable) return { kind: 'empty' }

  const ip = guestPrimaryIp(input.guest)
  const pfs = input.portForwards

  if (input.isMember) {
    if (ip) return bridgedIpView(ip, pfs)
    if (pfs.length > 0) {
      return {
        kind: 'port-map',
        labels: pfs.map((pf) => `${pf.hostPort}→${pf.guestPort}`),
      }
    }
    return { kind: 'empty' }
  }

  if (!input.isLocalNat && ip) return bridgedIpView(ip, pfs)
  if (input.isLocalNat && pfs.length > 0) {
    return { kind: 'nat-localhost', hostPorts: pfs.map((pf) => pf.hostPort) }
  }
  return { kind: 'empty' }
}

function bridgedIpView(ip: string, pfs: PortForwardRule[]): GuestIpPortsView {
  if (pfs.length === 0) {
    return { kind: 'bridged-ip', ip, links: [{ label: ip, copyText: ip }] }
  }
  return {
    kind: 'bridged-ip',
    ip,
    links: pfs.map((pf) => {
      const label = guestServiceLabel(ip, pf.guestPort)
      return { label, copyText: label, href: guestServiceHref(ip, pf.guestPort) }
    }),
  }
}
