import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isLoginPayload, LOGIN_URI_PREFIX } from './loginOffer'

const here = dirname(fileURLToPath(import.meta.url))

describe('PAS-242 phone sign-in offer', () => {
  test('login URI is not a pairing URI', () => {
    expect(LOGIN_URI_PREFIX).toBe('barkvisor://login/v1')
    expect(
      isLoginPayload('  barkvisor://login/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777  '),
    ).toBe(true)
    expect(isLoginPayload('barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777')).toBe(
      false,
    )
  })

  test('Settings issues a sign-in QR separate from pairing', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain('issueLoginOffer')
    expect(settings).toContain('loginOffer')
    expect(settings).toContain('Copy URI')
    expect(settings).toContain('Phone sign-in')
    expect(settings).toContain('advertisedHostForOffer')
    expect(settings).toContain('customHost.value')
    expect(settings).not.toContain('barkvisor://pair/v1?code')
    expect(settings).not.toMatch(/\b(cluster|node)s?\b/i)
  })
})
