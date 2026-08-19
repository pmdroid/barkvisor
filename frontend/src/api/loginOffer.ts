import axios from 'axios'
import api from './client'

export const LOGIN_URI_PREFIX = 'barkvisor://login/v1'
export const PAIRING_URI_PREFIX = 'barkvisor://pair/v1'

export interface LoginOffer {
  code: string
  expiresAt: string
  ttlSeconds: number
  uri: string
  host: string
  port: number
}

export function isLoginPayload(raw: string): boolean {
  return raw.trim().startsWith(LOGIN_URI_PREFIX)
}

export async function issueLoginOffer(advertisedHost?: string): Promise<LoginOffer> {
  const trimmed = advertisedHost?.trim()
  const body = trimmed ? { advertisedHost: trimmed } : {}
  const { data } = await api.post<LoginOffer>('/auth/login-offers', body)
  return data
}

export async function getLoginOffer(): Promise<LoginOffer | null> {
  try {
    const { data } = await api.get<LoginOffer>('/auth/login-offers')
    return data
  } catch (error) {
    if (axios.isAxiosError(error) && error.response?.status === 404) {
      return null
    }
    throw error
  }
}

export async function revokeLoginOffer(): Promise<void> {
  await api.delete('/auth/login-offers')
}
