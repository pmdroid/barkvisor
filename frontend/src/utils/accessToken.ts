/** Session JWT clock check. Opaque inference keys (`barkvisor_…`) are not JWTs. */
export function isAccessTokenExpired(token: string | null | undefined, now = Date.now()): boolean {
  if (!token) return true
  if (token.startsWith('barkvisor_')) return false
  const parts = token.split('.')
  if (parts.length !== 3 || parts.some((part) => part.length === 0)) return false
  try {
    const json = parts[1].replace(/-/g, '+').replace(/_/g, '/')
    const padded = json + '='.repeat((4 - (json.length % 4)) % 4)
    const payload = JSON.parse(atob(padded)) as { exp?: unknown }
    if (typeof payload.exp !== 'number') return false
    return payload.exp * 1000 < now
  } catch {
    return true
  }
}
