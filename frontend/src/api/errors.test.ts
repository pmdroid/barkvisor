import { describe, expect, test } from 'bun:test'
import { apiErrorMessage, isNotFoundError, isUnauthorizedError } from './errors'

function axiosResponse(status: number, reason?: string) {
  return {
    isAxiosError: true,
    message: reason ?? `Request failed with status code ${status}`,
    response: {
      status,
      data: reason ? { reason } : {},
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

  test('isUnauthorizedError matches HTTP 401 and stream status', () => {
    expect(isUnauthorizedError(axiosResponse(401, 'expired'))).toBe(true)
    expect(isUnauthorizedError(axiosResponse(403, 'forbidden'))).toBe(false)
    expect(isUnauthorizedError({ status: 401 })).toBe(true)
    expect(isUnauthorizedError(new Error('401'))).toBe(false)
  })
})
