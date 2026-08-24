import { describe, expect, test } from 'bun:test'
import {
  ollamaModelMatchesName,
  ollamaPullPercent,
  ollamaPullTaskPath,
  ollamaRunningHostId,
  ollamaStartBody,
} from './ollamaTask'

describe('ollama pull/start helpers (PAS-269)', () => {
  test('local pull uses Device task path', () => {
    expect(ollamaPullTaskPath({ taskID: 't1', hostId: 'self' }, 'self')).toBe('/tasks/t1')
  })

  test('member pull uses Home proxy task path', () => {
    expect(ollamaPullTaskPath({ taskID: 't1', hostId: 'peer/1' }, 'self')).toBe(
      '/home/devices/peer%2F1/v1/tasks/t1',
    )
  })

  test('Start does not pin a hostId from location order', () => {
    expect(ollamaStartBody('llama3:latest')).toEqual({ name: 'llama3:latest' })
    expect('hostId' in ollamaStartBody('llama3:latest')).toBe(false)
  })

  test('Start includes hostId when a Device is picked', () => {
    expect(ollamaStartBody('llama3:latest', 'desk')).toEqual({
      name: 'llama3:latest',
      hostId: 'desk',
    })
  })

  test('name filter is case-insensitive and ignores blank query', () => {
    expect(ollamaModelMatchesName('llama3:latest', '')).toBe(true)
    expect(ollamaModelMatchesName('llama3:latest', '  ')).toBe(true)
    expect(ollamaModelMatchesName('llama3:latest', 'LLAMA')).toBe(true)
    expect(ollamaModelMatchesName('llama3:latest', 'mistral')).toBe(false)
  })

  test('Stop uses the live running host, not a stale snapshot', () => {
    const live = {
      running: true,
      locations: [
        { hostId: 'old', running: false },
        { hostId: 'desk', running: true },
      ],
    }
    expect(ollamaRunningHostId(live)).toBe('desk')
    expect(ollamaRunningHostId({ running: false, locations: live.locations })).toBeUndefined()
    expect(ollamaRunningHostId(undefined)).toBeUndefined()
  })

  test('pull progress is a percent', () => {
    expect(ollamaPullPercent(0.42)).toBe(42)
    expect(ollamaPullPercent(null)).toBeUndefined()
  })
})
