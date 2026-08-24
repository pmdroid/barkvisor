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

/** Confirmed HTTP 404 / not-found. Network and 5xx must not evict last-known data. */
export function isNotFoundError(error: unknown): boolean {
  return axios.isAxiosError(error) && error.response?.status === 404
}

/** Access JWT expired or missing. Callers may silent-refresh then retry once. */
export function isUnauthorizedError(error: unknown): boolean {
  if (axios.isAxiosError(error)) {
    return error.response?.status === 401
  }
  return (
    typeof error === 'object' &&
    error !== null &&
    'status' in error &&
    (error as { status: unknown }).status === 401
  )
}
