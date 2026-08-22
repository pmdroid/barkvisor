import api from './client'

export interface TOTPStatus {
  enabled: boolean
  pending: boolean
  recoveryCodesRemaining: number
  enabledAt?: string | null
}

export interface TOTPSetup {
  secret: string
  otpauthUrl: string
  issuer: string
  account: string
}

export interface LoginChallenge {
  totpRequired: true
  challengeToken: string
  challengeExpiresAt: string
}

export function isLoginChallenge(value: unknown): value is LoginChallenge {
  if (!value || typeof value !== 'object') return false
  const rec = value as Record<string, unknown>
  return (
    rec.totpRequired === true &&
    typeof rec.challengeToken === 'string' &&
    rec.challengeToken.length > 0
  )
}

export async function getTOTPStatus(): Promise<TOTPStatus> {
  const { data } = await api.get<TOTPStatus>('/auth/totp')
  return data
}

export async function beginTOTPSetup(): Promise<TOTPSetup> {
  const { data } = await api.post<TOTPSetup>('/auth/totp/setup')
  return data
}

export async function confirmTOTPSetup(code: string): Promise<string[]> {
  const { data } = await api.post<{ recoveryCodes: string[] }>('/auth/totp/confirm', { code })
  return data.recoveryCodes
}

export async function disableTOTP(password: string, code: string): Promise<void> {
  await api.post('/auth/totp/disable', { password, code })
}

export async function regenerateRecoveryCodes(code: string): Promise<string[]> {
  const { data } = await api.post<{ recoveryCodes: string[] }>('/auth/totp/recovery-codes', { code })
  return data.recoveryCodes
}
