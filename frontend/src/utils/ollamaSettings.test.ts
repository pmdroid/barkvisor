import { describe, expect, test } from 'bun:test'
import {
  ollamaSettingsBackendBody,
  ollamaSettingsKeyBody,
  parseInferenceBackend,
} from './ollamaSettings'

describe('ollama settings key body', () => {
  test('omits apiKey when the draft is blank', () => {
    expect(ollamaSettingsKeyBody('desk', '')).toBeNull()
    expect(ollamaSettingsKeyBody('desk', '   ')).toBeNull()
    expect(ollamaSettingsKeyBody('', 'secret')).toBeNull()
  })

  test('includes a trimmed key when the draft is set', () => {
    expect(ollamaSettingsKeyBody(' desk ', ' secret ')).toEqual({
      hostId: 'desk',
      apiKey: 'secret',
    })
    expect(Object.keys(ollamaSettingsKeyBody('desk', 'secret') ?? {})).toEqual([
      'hostId',
      'apiKey',
    ])
  })
})

describe('ollama settings backend body', () => {
  test('unknown, empty, or blank backend falls back to ollama', () => {
    expect(parseInferenceBackend('unsloth')).toBe('unsloth')
    expect(parseInferenceBackend(' Unsloth ')).toBe('unsloth')
    expect(parseInferenceBackend('UNSLOTH')).toBe('unsloth')
    expect(parseInferenceBackend('ollama')).toBe('ollama')
    expect(parseInferenceBackend('')).toBe('ollama')
    expect(parseInferenceBackend('vllm')).toBe('ollama')
    expect(parseInferenceBackend(null)).toBe('ollama')
    expect(parseInferenceBackend(undefined)).toBe('ollama')
  })

  test('builds a PUT body with a normalized backend', () => {
    expect(ollamaSettingsBackendBody(' desk ', 'unsloth')).toEqual({
      hostId: 'desk',
      backend: 'unsloth',
    })
    expect(ollamaSettingsBackendBody('desk', '')).toEqual({
      hostId: 'desk',
      backend: 'ollama',
    })
    expect(Object.keys(ollamaSettingsBackendBody('desk', 'unsloth') ?? {})).toEqual([
      'hostId',
      'backend',
    ])
  })

  test('needs a host', () => {
    expect(ollamaSettingsBackendBody('', 'unsloth')).toBeNull()
    expect(ollamaSettingsBackendBody('   ', 'unsloth')).toBeNull()
  })
})
