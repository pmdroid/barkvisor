import { describe, expect, test } from 'bun:test'
import {
  isCurrentPairingSeq,
  nextPairingLoadSeq,
  pairingExpiryLabel,
  remainingPairingSeconds,
} from './pairingOffer'

describe('pairing offer expiry', () => {
  test('ticks remaining time from expiresAt, not a frozen ttl snapshot', () => {
    const expiresAt = '2026-08-16T22:10:00.000Z'
    const issued = Date.parse('2026-08-16T22:00:00.000Z')
    expect(remainingPairingSeconds(expiresAt, issued)).toBe(600)
    expect(pairingExpiryLabel(expiresAt, issued)).toBe('Expires in 10 minutes')
    expect(pairingExpiryLabel(expiresAt, issued + 9 * 60 * 1000)).toBe('Expires in 1 minute')
    expect(pairingExpiryLabel(expiresAt, Date.parse(expiresAt))).toBe('Expired')
    expect(pairingExpiryLabel(expiresAt, Date.parse(expiresAt) + 1_000)).toBe('Expired')
  })

  test('invalid expiry is treated as expired', () => {
    expect(remainingPairingSeconds('not-a-date', Date.now())).toBe(0)
    expect(pairingExpiryLabel('not-a-date', Date.now())).toBe('Expired')
  })
})

describe('pairing offer load sequence', () => {
  test('stale GET does not win after a newer issue or revoke', () => {
    expect(isCurrentPairingSeq(1, 1)).toBe(true)
    expect(isCurrentPairingSeq(1, 2)).toBe(false)
  })

  test('a GET started during POST does not share the mutation sequence', () => {
    expect(nextPairingLoadSeq(true, 4)).toBeNull()
    const loadSeq = nextPairingLoadSeq(false, 4)
    expect(loadSeq).toBe(5)
    expect(isCurrentPairingSeq(4, loadSeq!)).toBe(false)
    expect(isCurrentPairingSeq(loadSeq!, 5)).toBe(true)
  })
})
