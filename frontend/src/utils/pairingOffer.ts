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

/** True while the offer can still be redeemed. */
export function isPairingOfferActive(expiresAt: string, nowMs: number): boolean {
  return remainingPairingSeconds(expiresAt, nowMs) > 0
}

/** Drop a GET result when issue/revoke already advanced the sequence. */
export function isCurrentPairingSeq(loadSeq: number, latestSeq: number): boolean {
  return loadSeq === latestSeq
}

/**
 * Sequence for a pairing GET. Skip while a POST/revoke is in flight so the
 * GET cannot share that mutation's sequence and overwrite the new offer.
 * Otherwise advance so an older GET cannot commit after a newer load.
 */
export function nextPairingLoadSeq(loading: boolean, currentSeq: number): number | null {
  if (loading) return null
  return currentSeq + 1
}
