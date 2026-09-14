import type { HomeDeviceHealthSnapshot } from '../api/types'

/** The latest Home health report is the client-side authority for member hops. */
const statusByHostId = new Map<string, string>()

export function updateMemberReachability(
  rows: Array<Pick<HomeDeviceHealthSnapshot, 'hostId' | 'role' | 'reachability'>>,
): void {
  statusByHostId.clear()
  for (const row of rows) {
    if (row.role !== 'self') statusByHostId.set(row.hostId, row.reachability)
  }
}

export function markMemberTransportUnavailable(hostId: string): void {
  if (statusByHostId.has(hostId)) statusByHostId.set(hostId, 'unreachable')
}

/** Unknown members remain callable so first-load and pairing can establish health. */
export function canCallMember(hostId: string): boolean {
  const status = statusByHostId.get(hostId)
  return status == null || status === 'ok'
}

export function memberHostIdFromProxyPath(url: unknown): string | null {
  if (typeof url !== 'string') return null
  const match = url.match(/\/home\/devices\/([^/]+)\/v1(?:\/|$)/)
  if (!match?.[1]) return null
  try {
    return decodeURIComponent(match[1])
  } catch {
    return null
  }
}
