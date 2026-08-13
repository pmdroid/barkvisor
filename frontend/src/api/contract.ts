/** Published HTTP contract (PAS-78). Keep in sync with `APIContract` / OpenAPI. */
export const API_VERSION = 1
export const API_VERSION_HEADER = 'X-BarkVisor-API-Version'
export const OPENAPI_PATH = '/api/openapi.yaml'
export const CONTRACT_PATH = '/api/contract'

export const ERROR_ENVELOPE_KEYS = ['error', 'code', 'reason', 'status'] as const

export interface APIErrorEnvelope {
  error: true
  code: string
  reason: string
  status: number
}

export function isAPIErrorEnvelope(value: unknown): value is APIErrorEnvelope {
  if (!value || typeof value !== 'object') return false
  const rec = value as Record<string, unknown>
  return (
    rec.error === true &&
    typeof rec.code === 'string' &&
    typeof rec.reason === 'string' &&
    typeof rec.status === 'number'
  )
}
