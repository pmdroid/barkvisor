import type { PairingJoin } from './pairing'
import type { SetupStatus } from './setup'

/** sessionStorage key for a successful SetupView join that has not finished setup. */
export const SETUP_JOIN_PROGRESS_KEY = 'barkvisor.setup.join'

export function loadSetupJoinProgress(): PairingJoin | null {
  try {
    const raw = sessionStorage.getItem(SETUP_JOIN_PROGRESS_KEY)
    if (!raw) return null
    return parseSetupJoinProgress(raw)
  } catch {
    return null
  }
}

export function saveSetupJoinProgress(result: PairingJoin): void {
  try {
    sessionStorage.setItem(SETUP_JOIN_PROGRESS_KEY, JSON.stringify(result))
  } catch {
    // Private mode / blocked storage — join stays in component state only.
  }
}

export function clearSetupJoinProgress(): void {
  try {
    sessionStorage.removeItem(SETUP_JOIN_PROGRESS_KEY)
  } catch {
    // Ignore blocked storage.
  }
}

/** Resume join-ready from sessionStorage or a server-side pairing receipt. */
export function shouldResumeJoinReady(
  status: Pick<SetupStatus, 'complete' | 'joined'>,
  saved: PairingJoin | null,
): boolean {
  if (status.complete) return false
  return saved != null || status.joined === true
}

export function parseSetupJoinProgress(raw: string): PairingJoin | null {
  let value: unknown
  try {
    value = JSON.parse(raw)
  } catch {
    return null
  }
  if (!value || typeof value !== 'object') return null
  const rec = value as Record<string, unknown>
  if (
    typeof rec.peerHostId !== 'string' ||
    rec.peerHostId.length === 0 ||
    typeof rec.peerFingerprint !== 'string' ||
    rec.peerFingerprint.length === 0 ||
    typeof rec.issuedFingerprint !== 'string' ||
    rec.issuedFingerprint.length === 0 ||
    typeof rec.agentPort !== 'number' ||
    !Number.isInteger(rec.agentPort) ||
    rec.agentPort < 1 ||
    rec.agentPort > 65_535 ||
    typeof rec.pinned !== 'boolean' ||
    typeof rec.apiVersion !== 'number' ||
    !Number.isInteger(rec.apiVersion)
  ) {
    return null
  }
  return {
    peerHostId: rec.peerHostId,
    peerFingerprint: rec.peerFingerprint,
    issuedFingerprint: rec.issuedFingerprint,
    agentPort: rec.agentPort,
    pinned: rec.pinned,
    apiVersion: rec.apiVersion,
  }
}
