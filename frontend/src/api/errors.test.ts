import { describe, expect, test } from 'bun:test'
import { apiErrorCode, apiErrorMessage, isNotFoundError } from './errors'

function axiosResponse(status: number, reason?: string, code?: string) {
  return {
    isAxiosError: true,
    message: reason ?? `Request failed with status code ${status}`,
    response: {
      status,
      data: { ...(reason ? { reason } : {}), ...(code ? { code } : {}) },
    },
  }
}

describe('isNotFoundError (PAS-202)', () => {
  test('only confirmed HTTP 404 evicts last-known Workload data', () => {
    expect(isNotFoundError(axiosResponse(404, 'Workload not found'))).toBe(true)
    expect(isNotFoundError(axiosResponse(404))).toBe(true)
    expect(isNotFoundError(axiosResponse(502, 'Device is unreachable'))).toBe(false)
    expect(isNotFoundError(axiosResponse(503, 'Device registry is unavailable'))).toBe(false)
    expect(isNotFoundError(axiosResponse(500))).toBe(false)
    expect(isNotFoundError({ isAxiosError: true, message: 'Network Error' })).toBe(false)
    expect(isNotFoundError(new Error('not found'))).toBe(false)
    expect(isNotFoundError('not found')).toBe(false)
  })

  test('apiErrorMessage still prefers the Abort reason', () => {
    expect(apiErrorMessage(axiosResponse(502, 'Device is unreachable'))).toBe('Device is unreachable')
    expect(apiErrorMessage(axiosResponse(404, 'Workload not found'))).toBe('Workload not found')
  })
})

describe('apiErrorCode (GH-461)', () => {
  test('returns the typed code from the error envelope', () => {
    expect(apiErrorCode(axiosResponse(403, 'Grant Full Disk Access', 'permission_denied'))).toBe(
      'permission_denied',
    )
    expect(apiErrorCode(axiosResponse(403, 'Access denied', 'forbidden'))).toBe('forbidden')
  })

  test('returns null without an envelope code', () => {
    expect(apiErrorCode(axiosResponse(500))).toBe(null)
    expect(apiErrorCode({ isAxiosError: true, message: 'Network Error' })).toBe(null)
    expect(apiErrorCode(new Error('boom'))).toBe(null)
    expect(apiErrorCode('boom')).toBe(null)
  })
})
