function padBase64(s: string): string {
  const pad = s.length % 4
  if (pad === 0) return s
  return s + '='.repeat(4 - pad)
}

export function bufferFromBase64url(value: string): ArrayBuffer {
  const b64 = padBase64(value.replace(/-/g, '+').replace(/_/g, '/'))
  const binary = atob(b64)
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  return bytes.buffer
}

export function base64urlFromBuffer(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer)
  let binary = ''
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]!)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

export function isIPHostname(hostname: string): boolean {
  if (hostname.includes(':')) return true
  const parts = hostname.split('.')
  if (parts.length !== 4) return false
  return parts.every((part) => {
    if (!/^\d{1,3}$/.test(part)) return false
    const n = Number(part)
    return n >= 0 && n <= 255
  })
}

export type PasskeyWindow = {
  isSecureContext: boolean
  PublicKeyCredential?: unknown
  location: { hostname: string; port?: string }
}

export type PasskeyBlock = {
  reason: string
  fix: string
}

function servePort(win: PasskeyWindow): string {
  const port = win.location.port
  if (port && port !== '80' && port !== '443') return port
  return '7777'
}

export function passkeyBlock(
  win: PasskeyWindow | undefined = typeof window === 'undefined' ? undefined : window,
): PasskeyBlock | null {
  if (!win) {
    return {
      reason: 'Passkeys need a browser.',
      fix: 'Open this page in Chrome, Safari, or Firefox.',
    }
  }
  const host = win.location.hostname
  const port = servePort(win)
  const local = `http://localhost:${port}`
  if (isIPHostname(host)) {
    return {
      reason: `This page is ${host} — a raw IP. Passkeys need a hostname.`,
      fix: `On this Device open ${local}. Off-LAN use MagicDNS over https, not a 100.x address.\ntailscale serve --bg ${port}\nThen https://<magicdns>`,
    }
  }
  if (!win.isSecureContext) {
    if (host.endsWith('.ts.net') || host.endsWith('.tailscale.net')) {
      return {
        reason: `http://${host} is not https. Passkeys will not run here.`,
        fix: `On this Device run:\ntailscale serve --bg ${port}\nThen open https://${host}`,
      }
    }
    return {
      reason: 'This page is not https or localhost. Passkeys will not run here.',
      fix: `On this Device open ${local}, or put HTTPS in front:\ntailscale serve --bg ${port}\nThen https://${host}`,
    }
  }
  if (typeof win.PublicKeyCredential === 'undefined') {
    return {
      reason: 'This browser cannot create passkeys.',
      fix: 'Use current Chrome, Safari, or Firefox.',
    }
  }
  return null
}

export function isPasskeyAvailable(
  win: PasskeyWindow | undefined = typeof window === 'undefined' ? undefined : window,
): boolean {
  return passkeyBlock(win) === null
}

export function passkeyUnavailableMessage(
  win: PasskeyWindow | undefined = typeof window === 'undefined' ? undefined : window,
): string {
  const block = passkeyBlock(win)
  if (!block) return ''
  return `${block.reason} ${block.fix}`
}

type JSONObject = Record<string, unknown>

function isJSONObject(value: unknown): value is JSONObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function convertDescriptorList(value: unknown): PublicKeyCredentialDescriptor[] | undefined {
  if (!Array.isArray(value)) return undefined
  return value.map((item) => {
    const row = isJSONObject(item) ? item : {}
    const id = typeof row.id === 'string' ? bufferFromBase64url(row.id) : new ArrayBuffer(0)
    const transports = Array.isArray(row.transports)
      ? (row.transports.filter((t) => typeof t === 'string') as AuthenticatorTransport[])
      : undefined
    return {
      type: 'public-key' as const,
      id,
      transports,
    }
  })
}

export function toCreationOptions(publicKey: JSONObject): PublicKeyCredentialCreationOptions {
  const user = isJSONObject(publicKey.user) ? publicKey.user : {}
  const rp = isJSONObject(publicKey.rp) ? publicKey.rp : {}
  const selection = isJSONObject(publicKey.authenticatorSelection) ? publicKey.authenticatorSelection : undefined
  return {
    challenge: typeof publicKey.challenge === 'string' ? bufferFromBase64url(publicKey.challenge) : new ArrayBuffer(0),
    rp: {
      id: typeof rp.id === 'string' ? rp.id : undefined,
      name: typeof rp.name === 'string' ? rp.name : '',
    },
    user: {
      id: typeof user.id === 'string' ? bufferFromBase64url(user.id) : new ArrayBuffer(0),
      name: typeof user.name === 'string' ? user.name : '',
      displayName: typeof user.displayName === 'string' ? user.displayName : '',
    },
    pubKeyCredParams: Array.isArray(publicKey.pubKeyCredParams)
      ? (publicKey.pubKeyCredParams as PublicKeyCredentialParameters[])
      : [{ type: 'public-key', alg: -7 }],
    timeout: typeof publicKey.timeout === 'number' ? publicKey.timeout : undefined,
    attestation: typeof publicKey.attestation === 'string' ? (publicKey.attestation as AttestationConveyancePreference) : undefined,
    authenticatorSelection: selection
      ? {
          authenticatorAttachment:
            typeof selection.authenticatorAttachment === 'string'
              ? (selection.authenticatorAttachment as AuthenticatorAttachment)
              : undefined,
          residentKey:
            typeof selection.residentKey === 'string'
              ? (selection.residentKey as ResidentKeyRequirement)
              : undefined,
          requireResidentKey: selection.requireResidentKey === true,
          userVerification:
            typeof selection.userVerification === 'string'
              ? (selection.userVerification as UserVerificationRequirement)
              : undefined,
        }
      : undefined,
    excludeCredentials: convertDescriptorList(publicKey.excludeCredentials),
  }
}

export function toRequestOptions(publicKey: JSONObject): PublicKeyCredentialRequestOptions {
  return {
    challenge: typeof publicKey.challenge === 'string' ? bufferFromBase64url(publicKey.challenge) : new ArrayBuffer(0),
    timeout: typeof publicKey.timeout === 'number' ? publicKey.timeout : undefined,
    rpId: typeof publicKey.rpId === 'string' ? publicKey.rpId : undefined,
    allowCredentials: convertDescriptorList(publicKey.allowCredentials),
    userVerification:
      typeof publicKey.userVerification === 'string'
        ? (publicKey.userVerification as UserVerificationRequirement)
        : undefined,
  }
}

export function credentialToJSON(credential: PublicKeyCredential): JSONObject {
  const response = credential.response
  const json: JSONObject = {
    id: credential.id,
    rawId: base64urlFromBuffer(credential.rawId),
    type: credential.type,
    response: {},
  }
  const body = json.response as JSONObject
  body.clientDataJSON = base64urlFromBuffer(response.clientDataJSON)
  if (response instanceof AuthenticatorAttestationResponse) {
    body.attestationObject = base64urlFromBuffer(response.attestationObject)
    if (typeof response.getTransports === 'function') {
      body.transports = response.getTransports()
    }
  } else if (response instanceof AuthenticatorAssertionResponse) {
    body.authenticatorData = base64urlFromBuffer(response.authenticatorData)
    body.signature = base64urlFromBuffer(response.signature)
    if (response.userHandle) body.userHandle = base64urlFromBuffer(response.userHandle)
  }
  if (credential.authenticatorAttachment) {
    json.authenticatorAttachment = credential.authenticatorAttachment
  }
  return json
}

export async function createPasskey(publicKey: JSONObject): Promise<JSONObject> {
  const credential = await navigator.credentials.create({ publicKey: toCreationOptions(publicKey) })
  if (!(credential instanceof PublicKeyCredential)) {
    throw new Error('Passkey creation was cancelled')
  }
  return credentialToJSON(credential)
}

export async function getPasskey(publicKey: JSONObject): Promise<JSONObject> {
  const credential = await navigator.credentials.get({ publicKey: toRequestOptions(publicKey) })
  if (!(credential instanceof PublicKeyCredential)) {
    throw new Error('Passkey sign-in was cancelled')
  }
  return credentialToJSON(credential)
}
