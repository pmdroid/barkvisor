import { describe, expect, test } from 'bun:test'
import { isAccessTokenExpired } from './accessToken'

function jwt(exp: number): string {
  const payload = btoa(JSON.stringify({ exp }))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '')
  return `e30.${payload}.sig`
}

describe('isAccessTokenExpired', () => {
  test('treats missing tokens as expired', () => {
    expect(isAccessTokenExpired(null)).toBe(true)
    expect(isAccessTokenExpired('')).toBe(true)
  })

  test('does not treat minted inference keys as expired JWTs', () => {
    expect(isAccessTokenExpired('barkvisor_live_secret')).toBe(false)
    expect(isAccessTokenExpired('opaque-api-key')).toBe(false)
  })

  test('reads exp from a session JWT', () => {
    const now = 1_800_000_000_000
    expect(isAccessTokenExpired(jwt(1_700_000_000), now)).toBe(true)
    expect(isAccessTokenExpired(jwt(1_900_000_000), now)).toBe(false)
  })
})
