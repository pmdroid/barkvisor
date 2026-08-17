/** Remaining TTL from the offer's absolute expiry, not the issued ttlSeconds snapshot. */
export function remainingPairingSeconds(expiresAt: string, nowMs: number): number {
  const expires = Date.parse(expiresAt)
  if (Number.isNaN(expires)) return 0
  return Math.max(0, Math.floor((expires - nowMs) / 1000))
}

export function pairingExpiryLabel(expiresAt: string, nowMs: number): string {
  const seconds = remainingPairingSeconds(expiresAt, nowMs)
  if (seconds === 0) return 'Expired'
  const minutes = Math.ceil(seconds / 60)
  return minutes === 1 ? 'Expires in 1 minute' : `Expires in ${minutes} minutes`
}

/** Drop a GET result when issue/revoke already advanced the sequence. */
export function isCurrentPairingSeq(loadSeq: number, latestSeq: number): boolean {
  return loadSeq === latestSeq
}
