import { describe, expect, test } from 'bun:test'
import { pollUntilHealthy } from './updateHealthPoll'

describe('pollUntilHealthy', () => {
  test('returns ok when /api/health succeeds', async () => {
    let calls = 0
    const result = await pollUntilHealthy({
      health: async () => {
        calls += 1
        return calls >= 2
      },
      now: (() => {
        let t = 0
        return () => {
          t += 1
          return t
        }
      })(),
      sleep: async () => {},
      intervalMs: 1,
      timeoutMs: 10,
    })
    expect(result).toBe('ok')
    expect(calls).toBe(2)
  })

  test('returns timeout when health never comes back', async () => {
    const result = await pollUntilHealthy({
      health: async () => {
        throw new Error('down')
      },
      now: (() => {
        let t = 0
        return () => {
          const value = t
          t += 5
          return value
        }
      })(),
      sleep: async () => {},
      intervalMs: 5,
      timeoutMs: 10,
    })
    expect(result).toBe('timeout')
  })
})
