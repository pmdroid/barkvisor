import { describe, expect, test } from 'bun:test'
import api, { HOME_MEMBER_PROXY_TIMEOUT_MS } from './client'

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

  test('Home device list and health are not member hops', async () => {
    const ok = {
      data: {},
      status: 200,
      statusText: 'OK',
      headers: {},
    }
    const timeouts: Record<string, number | undefined> = {}
    for (const url of [
      '/home/devices/health',
      '/home/devices',
      '/home/devices/peer-1',
    ]) {
      await api.request({
        url,
        adapter: async (config) => {
          timeouts[url] = config.timeout
          return { ...ok, config }
        },
      })
    }
    expect(timeouts['/home/devices/health']).not.toBe(HOME_MEMBER_PROXY_TIMEOUT_MS)
    expect(timeouts['/home/devices']).not.toBe(HOME_MEMBER_PROXY_TIMEOUT_MS)
    expect(timeouts['/home/devices/peer-1']).not.toBe(HOME_MEMBER_PROXY_TIMEOUT_MS)
  })
})
