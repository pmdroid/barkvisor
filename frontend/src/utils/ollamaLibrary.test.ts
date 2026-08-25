import { describe, expect, test } from 'bun:test'
import { ollamaLibraryResultName, ollamaLibrarySearchQuery } from './ollamaLibrary'

describe('ollama library search helpers', () => {
  test('query helper treats blank as empty', () => {
    expect(ollamaLibrarySearchQuery('')).toBeNull()
    expect(ollamaLibrarySearchQuery('  ')).toBeNull()
    expect(ollamaLibrarySearchQuery(' llama3 ')).toBe('llama3')
  })

  test('result name is the pull name', () => {
    expect(ollamaLibraryResultName({ name: ' llama3.2 ' })).toBe('llama3.2')
    expect(ollamaLibraryResultName({ name: '' })).toBe('')
    expect(ollamaLibraryResultName({ name: null })).toBe('')
    expect(ollamaLibraryResultName(undefined)).toBe('')
  })
})
