import api from './client'
import type { AuthMode } from '../utils/authMode'

export interface SecuritySettings {
  authMode: AuthMode
  persistedAuthMode: AuthMode
  envLocked: boolean
}

export async function getSecuritySettings(): Promise<SecuritySettings> {
  const { data } = await api.get<SecuritySettings>('/settings/security')
  return data
}

export async function saveSecuritySettings(
  authMode: AuthMode,
  acknowledged = false,
): Promise<SecuritySettings> {
  const { data } = await api.put<SecuritySettings>('/settings/security', {
    authMode,
    acknowledged,
  })
  return data
}
