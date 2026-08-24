import { describe, expect, test } from 'bun:test'
import { ollamaSettingsKeyBody } from './ollamaSettings'

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
