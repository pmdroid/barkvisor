import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isLoginChallenge } from './totp'

const here = dirname(fileURLToPath(import.meta.url))

describe('PAS-86 TOTP', () => {
  test('login challenge is distinct from a session payload', () => {
    expect(
      isLoginChallenge({
        totpRequired: true,
        challengeToken: 'bvch_abc',
        challengeExpiresAt: '2026-01-01T00:00:00Z',
      }),
    ).toBe(true)
    expect(isLoginChallenge({ token: 'jwt', refreshToken: 'bvrt_abc' })).toBe(false)
    expect(isLoginChallenge({ totpRequired: true, challengeToken: '' })).toBe(false)
  })

  test('Settings two-factor is separate from API keys', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain("tab === 'security'")
    expect(settings).toContain('beginTOTPSetup')
    expect(settings).toContain('recoveryCodes')
    expect(settings).toContain('Two-factor')
    expect(settings).toContain("tab === 'apikeys'")
    expect(settings).not.toMatch(/\b(cluster|node|datacenter|quorum)s?\b/i)
  })

  test('login view can complete a TOTP challenge', () => {
    const login = readFileSync(join(here, '../views/LoginView.vue'), 'utf8')
    expect(login).toContain('completeLoginChallenge')
    expect(login).toContain('challengeToken')
    expect(login).toContain('Authenticator code')
  })
})
