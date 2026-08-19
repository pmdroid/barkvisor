import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  CUSTOM_ADVERTISED_HOST,
  isPairingPayload,
  issuedAdvertisedHost,
  pairingHostFromPayload,
  PAIRING_URI_PREFIX,
} from './pairing'

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
    expect(setup).toContain('pairing-steps')
    expect(setup).toContain("barkvisor join --code 'barkvisor://pair/v1?…'")
    expect(setup).not.toMatch(/\b(?:nodes?|clusters?)\b/i)
    expect(setup).not.toContain('/api/pairing/redeem')
    expect(setup).not.toContain('OnboardingWizard')
  })

  test('Settings issues a pairing code on this Device', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain('issuePairingCode')
    expect(settings).toContain('Add a Device')
    expect(settings).toContain('HOME_LABEL')
    expect(settings).toContain('pairingSeq')
    expect(settings).toContain('pairingHydrating')
    expect(settings).toContain('isCurrentPairingSeq')
    expect(settings).toContain('nextPairingLoadSeq')
    expect(settings).toContain('pairingExpiryLabel(pairingOffer.expiresAt, pairingNow)')
    expect(settings).toContain('pairing-steps')
    expect(settings).toContain('CUSTOM_ADVERTISED_HOST')
    expect(settings).toContain('onAdvertisedHostChange')
    expect(settings).toContain('Other / DNS name')
    expect(settings).toContain('if (advertisedHost !== undefined)')
    expect(settings).toContain('pairingOffer.value = null')
    expect(settings).toContain('PairingQr')
    expect(settings).toContain(':payload="pairingOffer.qrPayload"')
    expect(settings).toContain(':key="pairingOffer.qrPayload"')
    expect(settings).toContain('v-if="isPairingOfferActive(pairingOffer.expiresAt, pairingNow)"')
    expect(settings).toContain('copyPairingPayload')
    expect(settings).toContain('v-if="!pairingOffer"')
    expect(settings).not.toMatch(/\b(cluster|node)s?\b/i)
  })

  test('Settings re-pairs through the existing join endpoint', () => {
    const pairing = readFileSync(join(here, 'pairing.ts'), 'utf8')
    expect(pairing).toContain("localStorage.getItem('token')")
    expect(pairing).toContain("api.post<PairingJoin>('/pairing/join'")
    expect(pairing).toContain("pairingApi.post<PairingJoin>('/join'")
    expect(pairing).not.toContain('/api/setup/recover-device')
    expect(pairing).not.toContain('recovery-blob')

    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain('joinHome')
    expect(settings).toContain('Re-pair this {{ DEVICE_LABEL }}')
    expect(settings).not.toContain('OnboardingWizard')
    expect(settings).not.toContain('/api/pairing/redeem')
    expect(settings).not.toMatch(/\b(cluster|node)s?\b/i)
  })

  test('POST pairing codes sends advertisedHost when picked', () => {
    const pairing = readFileSync(join(here, 'pairing.ts'), 'utf8')
    expect(pairing).toContain('{ advertisedHost: trimmed }')
    expect(pairing).toContain('advertisedHost?: string')
    expect(CUSTOM_ADVERTISED_HOST).toBe('__custom__')
    expect(
      pairingHostFromPayload(
        'barkvisor://pair/v1?code=ABCD-EFGH&host=100.64.0.8&port=7777&hostId=h&fp=abc',
      ),
    ).toBe('100.64.0.8')
    expect(
      issuedAdvertisedHost({
        advertisedHost: 'box.home.example',
        qrPayload: 'barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777',
      }),
    ).toBe('box.home.example')
    expect(
      issuedAdvertisedHost({
        qrPayload: 'barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777',
      }),
    ).toBe('192.168.0.8')
  })
})
