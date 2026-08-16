import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isPairingPayload, PAIRING_URI_PREFIX } from './pairing'

const here = dirname(fileURLToPath(import.meta.url))

describe('PAS-51 pairing client', () => {
  test('accepts the existing QR URI and rejects a short code', () => {
    expect(PAIRING_URI_PREFIX).toBe('barkvisor://pair/v1')
    expect(
      isPairingPayload(
        '  barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777&hostId=h&fp=abc  ',
      ),
    ).toBe(true)
    expect(isPairingPayload('ABCD-EFGH')).toBe(false)
    expect(isPairingPayload('https://example/pair')).toBe(false)
  })

  test('SetupView joins through /api/pairing/join only', () => {
    const setup = readFileSync(join(here, '../views/SetupView.vue'), 'utf8')
    expect(setup).toContain('joinHome')
    expect(setup).toContain('Join an existing {{ HOME_LABEL }}')
    expect(setup).toContain('HOME_LABEL')
    expect(setup).toContain('DEVICE_LABEL')
    expect(setup).not.toMatch(/\b(?:nodes?|clusters?)\b/i)
    expect(setup).not.toContain('/api/pairing/redeem')
    expect(setup).not.toContain('OnboardingWizard')
  })

  test('Settings issues a pairing code on this Device', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain('issuePairingCode')
    expect(settings).toContain('Add a Device')
    expect(settings).toContain('HOME_LABEL')
    expect(settings).not.toMatch(/\b(cluster|node)s?\b/i)
  })
})
