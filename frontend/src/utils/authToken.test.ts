import { describe, expect, test } from 'bun:test'
import { isTokenExpired } from './authToken'

describe('isTokenExpired', () => {
  test('inference API keys are not treated as expired JWTs', () => {
    expect(isTokenExpired('barkvisor_abc')).toBe(false)
    expect(isTokenExpired('barkvisor_live_key')).toBe(false)
  })

  test('JWT expiry uses the exp claim', () => {
    const encode = (exp: number) => Buffer.from(JSON.stringify({ exp })).toString('base64')
    expect(isTokenExpired(`eyJhbGciOiJIUzI1NiJ9.${encode(4_100_244_800)}.sig`)).toBe(false)
    expect(isTokenExpired(`eyJhbGciOiJIUzI1NiJ9.${encode(1)}.sig`)).toBe(true)
  })
})
