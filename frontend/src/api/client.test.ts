import { describe, expect, test } from 'bun:test'
import api, { MemberDeviceOfflineError } from './client'
import { updateMemberReachability } from '../utils/memberReachability'

Object.defineProperty(globalThis, 'localStorage', {
  value: { getItem: () => null },
  configurable: true,
})

describe('member proxy guard', () => {
  test('suppresses member requests while offline and permits recovery', async () => {
    let calls = 0
    const adapter = async () => {
      calls += 1
      return { data: { ok: true }, status: 200, statusText: 'OK', headers: {}, config: {} }
    }

    updateMemberReachability([{ hostId: 'garage', role: 'member', reachability: 'unreachable' }])
    await expect(api.get('/home/devices/garage/v1/vms', { adapter })).rejects.toBeInstanceOf(
      MemberDeviceOfflineError,
    )
    expect(calls).toBe(0)

    updateMemberReachability([{ hostId: 'garage', role: 'member', reachability: 'ok' }])
    await api.get('/home/devices/garage/v1/vms', { adapter })
    expect(calls).toBe(1)
  })
})
