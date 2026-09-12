export type AuthMode = 'secure' | 'loopback' | 'disabled'

export interface FrontDoorStatus {
  complete?: boolean
  authDisabled?: boolean
  authMode?: string
  proxied?: boolean
}

export function parseAuthMode(raw: unknown): AuthMode {
  if (raw === 'loopback' || raw === 'disabled' || raw === 'secure') return raw
  return 'secure'
}

export function isFrontDoorBypassed(status: FrontDoorStatus | null | undefined): boolean {
  return status?.authDisabled === true
}

export function authBannerText(mode: AuthMode): string {
  if (mode === 'loopback') {
    return 'Sign-in is disabled (this computer only). Re-enable in Settings → Security.'
  }
  if (mode === 'disabled') {
    return 'Sign-in is disabled (everyone on the network). Re-enable in Settings → Security.'
  }
  return ''
}

export function loopbackProxyWarning(mode: AuthMode, proxied: boolean): string {
  if (mode !== 'loopback' || !proxied) return ''
  return 'This request arrived through a reverse proxy. Skip-sign-in on this computer does not apply behind a proxy; remote callers still need a token.'
}
