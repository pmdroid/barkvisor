import { describe, expect, test } from 'bun:test'
import { ollamaPullPercent, ollamaPullTaskPath, ollamaStartBody } from './ollamaTask'

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

  test('pull progress is a percent', () => {
    expect(ollamaPullPercent(0.42)).toBe(42)
    expect(ollamaPullPercent(null)).toBeUndefined()
  })
})
