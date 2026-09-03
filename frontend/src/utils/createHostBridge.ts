import type { HostBridgeReadiness, HostInterface } from '../api/types'
import { inferInterfaceRole } from './hostInterfaceDisplay'

export function defaultMacBridgeName(nic: string, taken: Iterable<string> = []): string {
  const port = nic.trim()
  if (!port) return ''
  const base = `${port}-bridge`
  const set = new Set(taken)
  if (!set.has(base) && base.length < 16) return base
  for (let n = 2; n < 100; n++) {
    const name = `${base}-${n}`
    if (!set.has(name) && name.length < 16) return name
  }
  return base.slice(0, 15)
}

export function nextFreeBridgeName(taken: Iterable<string>): string {
  const set = new Set(taken)
  for (let n = 0; n < 1_024; n++) {
    const name = `br${n}`
    if (!set.has(name)) return name
  }
  return 'br0'
}

export function takenBridgeNames(
  ifaces: HostInterface[],
  readiness?: HostBridgeReadiness | null,
  extra: Iterable<string> = [],
): string[] {
  const names = new Set<string>()
  for (const iface of ifaces) {
    if (/^br\d+$/.test(iface.name)) names.add(iface.name)
  }
  for (const bridge of readiness?.bridges ?? []) {
    names.add(bridge.name)
  }
  for (const name of extra) {
    if (name) names.add(name)
  }
  return [...names]
}

export function isWirelessPort(iface: { name: string; displayName?: string }): boolean {
  const blob = `${iface.name} ${iface.displayName || ''}`.toLowerCase()
  if (blob.includes('wi-fi') || blob.includes('wifi') || blob.includes('airport')) return true
  const n = iface.name.toLowerCase()
  return n.startsWith('wlan') || n.startsWith('wlp') || n.startsWith('wlx') || /^wl\d/.test(n)
}

export function linuxRefusesWifiPort(
  iface: { name: string; displayName?: string },
  platform?: string | null,
): boolean {
  const os = (platform || '').toLowerCase()
  if (os === 'macos' || os === 'darwin') return false
  return isWirelessPort(iface)
}

function isMacPlatform(platform?: string | null): boolean {
  const os = (platform || '').toLowerCase()
  return os === 'macos' || os === 'darwin'
}

function isKernelBridgeName(name: string): boolean {
  return /^br\d+$/.test(name) || name.toLowerCase().startsWith('bridge')
}

export function unusedBridgePorts(
  ifaces: HostInterface[],
  readiness: HostBridgeReadiness | null | undefined,
  platform?: string | null,
): HostInterface[] {
  const mac = isMacPlatform(platform)
  const mode = mac ? 'macos-guide' : undefined
  const enslaved = new Set(
    (readiness?.bridges ?? []).flatMap((bridge) => {
      if (mac && !isKernelBridgeName(bridge.name)) return []
      return bridge.enslaved
    }),
  )
  const bridges = new Set(
    (readiness?.bridges ?? [])
      .map((bridge) => bridge.name)
      .filter((name) => !mac || isKernelBridgeName(name)),
  )
  return ifaces.filter((iface) => {
    if (iface.name === 'lo' || iface.name === 'lo0') return false
    if (bridges.has(iface.name)) return false
    if (enslaved.has(iface.name)) return false
    const role = inferInterfaceRole(iface, readiness, mode)
    if (role === 'bridge' || role === 'loopback' || role === 'tailscale') return false
    const n = iface.name.toLowerCase()
    if (n.startsWith('docker') || n.startsWith('veth') || n.startsWith('virbr')) return false
    if (linuxRefusesWifiPort(iface, platform)) return false
    return true
  })
}

export function defaultUnusedPort(
  ports: HostInterface[],
  readiness?: HostBridgeReadiness | null,
): string {
  const uplink = readiness?.defaultRouteInterface
  if (uplink && ports.some((port) => port.name === uplink)) return uplink
  return ports[0]?.name ?? ''
}
