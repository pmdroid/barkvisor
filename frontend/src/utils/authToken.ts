/** Inference API keys are not JWTs; the router must not treat them as expired. */
export const API_KEY_PREFIX = 'barkvisor_'

export function isTokenExpired(token: string, now: number = Date.now()): boolean {
  const trimmed = token.trim()
  if (!trimmed) return true
  if (trimmed.startsWith(API_KEY_PREFIX)) return false
  const parts = trimmed.split('.')
  if (parts.length !== 3) return false
  try {
    const payload = JSON.parse(atob(parts[1]))
    if (typeof payload?.exp !== 'number') return false
    return payload.exp * 1000 < now
  } catch {
    return false
  }
}
