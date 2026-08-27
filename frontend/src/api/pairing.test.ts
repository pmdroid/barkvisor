import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  advertisedHostForOffer,
  CUSTOM_ADVERTISED_HOST,
  isPairingPayload,
  issuedAdvertisedHost,
  pairingHostFromPayload,
  PAIRING_URI_PREFIX,
  syncAdvertiseHostPicker,
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

  test('SetupView is create-only; join is CLI', () => {
    const setup = readFileSync(join(here, '../views/SetupView.vue'), 'utf8')
    expect(setup).toContain('HOME_LABEL')
    expect(setup).toContain('DEVICE_LABEL')
    expect(setup).toContain('barkvisor join --code')
    expect(setup).toContain('Library folder')
    expect(setup).toContain('LibraryFolderForm')
    expect(setup).toContain('source="setup"')
    expect(setup).toContain('Add passkey')
    expect(setup).toContain('registerSetupPasskey')
    expect(setup).toContain('PasskeyBlocked')
    expect(setup).not.toContain('createAdmin')
    expect(setup).not.toContain('setup-password')
    expect(setup).not.toContain('joinHome')
    expect(setup).not.toContain('submitJoin')
    expect(setup).not.toContain('startJoin')
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
    expect(settings).toContain('CUSTOM_ADVERTISED_HOST')
    expect(settings).toContain('onAdvertisedHostChange')
    expect(settings).toContain('Other / DNS name')
    expect(settings).toContain('if (advertisedHost !== undefined)')
    expect(settings).toContain('pairingOffer.value = null')
    expect(settings).not.toContain('PairingQr')
    expect(settings).not.toContain(':payload="pairingOffer.qrPayload"')
    expect(settings).not.toContain(':key="pairingOffer.qrPayload"')
    expect(settings).not.toContain('isPairingOfferActive')
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
    expect(advertisedHostForOffer('100.64.0.8', 'ignored.example')).toBe('100.64.0.8')
    expect(advertisedHostForOffer(CUSTOM_ADVERTISED_HOST, '  box.home.example  ')).toBe(
      'box.home.example',
    )
    expect(advertisedHostForOffer(CUSTOM_ADVERTISED_HOST, '   ')).toBeUndefined()
  })

  test('advertise URL picker selects listed hosts or custom', () => {
    const hosts = ['studio.local', '192.168.0.8', '100.64.0.8', 'box.tailnet.ts.net']
    expect(syncAdvertiseHostPicker('192.168.0.8', hosts)).toEqual({
      selectedHost: '192.168.0.8',
      customHost: '',
    })
    expect(syncAdvertiseHostPicker('box.tailnet.ts.net', hosts)).toEqual({
      selectedHost: 'box.tailnet.ts.net',
      customHost: '',
    })
    expect(syncAdvertiseHostPicker('home.ts.net', hosts)).toEqual({
      selectedHost: CUSTOM_ADVERTISED_HOST,
      customHost: 'home.ts.net',
    })
    expect(syncAdvertiseHostPicker(null, hosts)).toEqual({
      selectedHost: CUSTOM_ADVERTISED_HOST,
      customHost: '',
    })
    expect(advertisedHostForOffer('100.64.0.8', '')).toBe('100.64.0.8')
    expect(advertisedHostForOffer(CUSTOM_ADVERTISED_HOST, '  nas.home  ')).toBe('nas.home')
    expect(advertisedHostForOffer(CUSTOM_ADVERTISED_HOST, '')).toBeUndefined()

    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain('syncAdvertiseHostPicker')
    expect(settings).toContain('advertiseHostOptions')
    expect(settings).toContain('advertiseSelected')
    expect(settings).toContain('Advertise URL')
    expect(settings).not.toContain('advertiseDraft')
    expect(settings).toContain("api.put<RemoteAccessStatus>('/home/settings/remote-access'")
  })
})
