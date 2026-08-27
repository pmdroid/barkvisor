import { describe, expect, test } from 'bun:test'
import {
  base64urlFromBuffer,
  bufferFromBase64url,
  isIPHostname,
  isPasskeyAvailable,
  passkeyBlock,
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
        isSecureContext: true,
        PublicKeyCredential: function PublicKeyCredential() {},
        location: { hostname: 'localhost' },
      }),
    ).toBe(true)
    expect(
      isPasskeyAvailable({
        isSecureContext: false,
        PublicKeyCredential: function PublicKeyCredential() {},
        location: { hostname: 'localhost' },
      }),
    ).toBe(false)
  })

  test('explains IP, Tailscale http, and missing https', () => {
    const cred = function PublicKeyCredential() {}
    const ip = passkeyBlock({
      isSecureContext: false,
      PublicKeyCredential: cred,
      location: { hostname: '127.0.0.1', port: '7777' },
    })
    expect(ip?.reason).toContain('127.0.0.1')
    expect(ip?.fix).toContain('http://localhost:7777')
    expect(ip?.fix).toContain('tailscale serve --bg 7777')

    const ts = passkeyBlock({
      isSecureContext: false,
      PublicKeyCredential: cred,
      location: { hostname: 'box.tail1234.ts.net', port: '7777' },
    })
    expect(ts?.reason).toContain('http://box.tail1234.ts.net')
    expect(ts?.fix).toContain('tailscale serve --bg 7777')
    expect(ts?.fix).toContain('https://box.tail1234.ts.net')

    const http = passkeyBlock({
      isSecureContext: false,
      PublicKeyCredential: cred,
      location: { hostname: 'barkvisor.local', port: '7777' },
    })
    expect(http?.reason).toContain('https or localhost')
    expect(http?.fix).toContain('http://localhost:7777')

    expect(passkeyBlock({
      isSecureContext: true,
      PublicKeyCredential: cred,
      location: { hostname: 'box.tail1234.ts.net' },
    })).toBeNull()

    expect(passkeyUnavailableMessage({
      isSecureContext: false,
      PublicKeyCredential: cred,
      location: { hostname: 'box.tail1234.ts.net', port: '7777' },
    })).toContain('https://box.tail1234.ts.net')
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
