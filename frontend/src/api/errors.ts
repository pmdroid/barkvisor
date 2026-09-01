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
