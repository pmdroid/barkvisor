import { describe, expect, test } from 'bun:test'
import api from './client'

Object.defineProperty(globalThis, 'localStorage', {
  value: { getItem: () => null },
  configurable: true,
})

describe('member proxy timeout', () => {
  test('sets a bounded timeout for member proxy requests', async () => {
    let calls = 0
    const adapter = async () => {
      calls += 1
      return { data: { ok: true }, status: 200, statusText: 'OK', headers: {}, config: {} }
    }

    await api.get('/home/devices/garage/v1/vms', { adapter })
    expect(calls).toBe(1)
  })
})
