import axios from 'axios'
import api from './client'

/** Join during first-run setup has no JWT; redeem/join stay the existing APIs. */
const pairingApi = axios.create({ baseURL: '/api/pairing' })

export const PAIRING_URI_PREFIX = 'barkvisor://pair/v1'

export function isPairingPayload(raw: string): boolean {
  return raw.trim().startsWith(PAIRING_URI_PREFIX)
}

export interface PairingIssue {
  code: string
  expiresAt: string
  ttlSeconds: number
  qrPayload: string
  hostId: string
  fingerprint: string
  caFingerprint: string
  port: number
  agentPort: number
  advertisedHost?: string
  advertisedHosts: string[]
  apiVersion: number
}

export const CUSTOM_ADVERTISED_HOST = '__custom__'

/** Host to stamp on a pairing or sign-in offer from the Settings picker. */
export function advertisedHostForOffer(selectedHost: string, customHost: string): string | undefined {
  if (selectedHost === CUSTOM_ADVERTISED_HOST) {
    const host = customHost.trim()
    return host.length > 0 ? host : undefined
  }
  const host = selectedHost.trim()
  return host.length > 0 ? host : undefined
}

/** Settings advertise-URL picker: listed host, or Other / DNS name. */
export function syncAdvertiseHostPicker(
  deviceUrl: string | null | undefined,
  advertisedHosts: string[],
): { selectedHost: string; customHost: string } {
  const host = deviceUrl?.trim() ?? ''
  if (host && advertisedHosts.includes(host)) {
    return { selectedHost: host, customHost: '' }
  }
  return { selectedHost: CUSTOM_ADVERTISED_HOST, customHost: host }
}

/** Host baked into a pairing URI (`host=`). */
export function pairingHostFromPayload(qrPayload: string): string | null {
  try {
    const host = new URL(qrPayload.trim()).searchParams.get('host')
    return host && host.length > 0 ? host : null
  } catch {
    return null
  }
}

export function issuedAdvertisedHost(offer: Pick<PairingIssue, 'advertisedHost' | 'qrPayload'>): string | null {
  const persisted = offer.advertisedHost?.trim()
  if (persisted) return persisted
  return pairingHostFromPayload(offer.qrPayload)
}

export interface PairingJoin {
  peerHostId: string
  peerFingerprint: string
  issuedFingerprint: string
  agentPort: number
  pinned: boolean
  apiVersion: number
}

/**
 * POST /api/pairing/join — SetupView join-Home (PAS-51) and Settings
 * re-pair after this Device is already set up (PAS-77).
 *
 * Setup has no JWT; after setup the same endpoint requires the session
 * token. Both paths stay on this one join surface.
 */
export async function joinHome(qrPayload: string): Promise<PairingJoin> {
  const body = { qrPayload: qrPayload.trim() }
  const token = typeof localStorage !== 'undefined' ? localStorage.getItem('token') : null
  if (token) {
    const { data } = await api.post<PairingJoin>('/pairing/join', body)
    return data
  }
  const { data } = await pairingApi.post<PairingJoin>('/join', body)
  return data
}

/** POST /api/pairing/codes — Add a Device on an existing Home. */
export async function issuePairingCode(advertisedHost?: string): Promise<PairingIssue> {
  const trimmed = advertisedHost?.trim()
  const body = trimmed ? { advertisedHost: trimmed } : {}
  const { data } = await api.post<PairingIssue>('/pairing/codes', body)
  return data
}

/** GET /api/pairing/codes — 404 means no unused code. */
export async function getPairingCode(): Promise<PairingIssue | null> {
  try {
    const { data } = await api.get<PairingIssue>('/pairing/codes')
    return data
  } catch (error) {
    if (axios.isAxiosError(error) && error.response?.status === 404) {
      return null
    }
    throw error
  }
}

export async function revokePairingCode(): Promise<void> {
  await api.delete('/pairing/codes')
}
