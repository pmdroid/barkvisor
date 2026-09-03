import axios from 'axios'

/**
 * Normalize API / network errors into a user-facing message.
 * Prefer server `reason` (BarkVisor Abort payload), then Error.message, then fallback.
 */
export function apiErrorMessage(error: unknown, fallback = 'Request failed'): string {
  if (axios.isAxiosError(error)) {
    const reason = error.response?.data?.reason
    if (typeof reason === 'string' && reason.length > 0) {
      return reason
    }
    if (typeof error.message === 'string' && error.message.length > 0) {
      return error.message
    }
  }
  if (error instanceof Error && error.message) {
    return error.message
  }
  if (typeof error === 'string' && error.length > 0) {
    return error
  }
  return fallback
}

export function apiErrorCode(error: unknown): string | null {
  if (axios.isAxiosError(error)) {
    const code = error.response?.data?.code
    if (typeof code === 'string' && code.length > 0) {
      return code
    }
  }
  return null
}

/** Confirmed HTTP 404 / not-found. Network and 5xx must not evict last-known data. */
export function isNotFoundError(error: unknown): boolean {
  return axios.isAxiosError(error) && error.response?.status === 404
}

export function isTransientHostApplyError(error: unknown): boolean {
  if (!axios.isAxiosError(error)) return false
  const status = error.response?.status
  if (status === 502 || status === 503 || status === 504) return true
  if (!error.response) return true
  return error.code === 'ECONNABORTED'
}

export function isOccupiedBridgeConflict(error: unknown, bridge: string): boolean {
  if (apiErrorCode(error) !== 'conflict') return false
  return apiErrorMessage(error).includes(`Interface '${bridge}' is already used`)
}
