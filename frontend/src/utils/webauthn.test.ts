import { describe, expect, test } from 'bun:test'
import {
  base64urlFromBuffer,
  bufferFromBase64url,
  isIPHostname,
  isPasskeyAvailable,
  passkeyUnavailableMessage,
  toCreationOptions,
  toRequestOptions,
} from './webauthn'

describe('webauthn helpers', () => {
  test('base64url roundtrips', () => {
    const bytes = new Uint8Array([1, 2, 3, 250, 255])
    const encoded = base64urlFromBuffer(bytes.buffer)
    expect(encoded).not.toContain('+')
    expect(encoded).not.toContain('/')
    expect(encoded).not.toContain('=')
    const back = new Uint8Array(bufferFromBase64url(encoded))
    expect([...back]).toEqual([1, 2, 3, 250, 255])
  })

  test('detects IP hostnames and passkey availability', () => {
    expect(isIPHostname('192.168.1.10')).toBe(true)
    expect(isIPHostname('::1')).toBe(true)
    expect(isIPHostname('localhost')).toBe(false)
    expect(isIPHostname('home.ts.net')).toBe(false)
    expect(isPasskeyAvailable(undefined)).toBe(false)
    expect(
      isPasskeyAvailable({
        isSecureContext: false,
        PublicKeyCredential: function PublicKeyCredential() {},
        location: { hostname: 'localhost' },
      }),
    ).toBe(false)
    expect(passkeyUnavailableMessage()).toContain('https')
    expect(passkeyUnavailableMessage()).toContain('hostname')
  })

  test('converts creation and request options', () => {
    const challenge = base64urlFromBuffer(new Uint8Array([9, 8, 7]).buffer)
    const userId = base64urlFromBuffer(new Uint8Array([1]).buffer)
    const create = toCreationOptions({
      challenge,
      rp: { id: 'localhost', name: 'BarkVisor' },
      user: { id: userId, name: 'admin', displayName: 'admin' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      authenticatorSelection: { residentKey: 'required', requireResidentKey: true, userVerification: 'preferred' },
    })
    expect(new Uint8Array(create.challenge)).toEqual(new Uint8Array([9, 8, 7]))
    expect(new Uint8Array(create.user.id)).toEqual(new Uint8Array([1]))
    expect(create.authenticatorSelection?.residentKey).toBe('required')

    const request = toRequestOptions({
      challenge,
      rpId: 'localhost',
      userVerification: 'preferred',
      allowCredentials: [{ type: 'public-key', id: challenge }],
    })
    expect(request.rpId).toBe('localhost')
    expect(request.allowCredentials?.[0]?.id).toBeInstanceOf(ArrayBuffer)
  })
})
