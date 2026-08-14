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
  advertisedHosts: string[]
  apiVersion: number
}

export interface PairingJoin {
  peerHostId: string
  peerFingerprint: string
  issuedFingerprint: string
  agentPort: number
  pinned: boolean
  apiVersion: number
}

/** POST /api/pairing/join — SetupView join-Home branch (PAS-51). */
export async function joinHome(qrPayload: string): Promise<PairingJoin> {
  const { data } = await pairingApi.post<PairingJoin>('/join', {
    qrPayload: qrPayload.trim(),
  })
  return data
}

/** POST /api/pairing/codes — Add a Device on an existing Home. */
export async function issuePairingCode(): Promise<PairingIssue> {
  const { data } = await api.post<PairingIssue>('/pairing/codes', {})
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
