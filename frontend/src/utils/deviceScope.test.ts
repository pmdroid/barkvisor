import { describe, expect, test } from 'bun:test'
import {
  DEVICE_SCOPE_ALL,
  parseDeviceScope,
  scopeLibraryItems,
  scopeOllamaModels,
  scopeRows,
} from './deviceScope'

describe('parseDeviceScope', () => {
  test('null, empty, and all map to all', () => {
    expect(parseDeviceScope(null)).toBe(DEVICE_SCOPE_ALL)
    expect(parseDeviceScope('')).toBe(DEVICE_SCOPE_ALL)
    expect(parseDeviceScope('  ')).toBe(DEVICE_SCOPE_ALL)
    expect(parseDeviceScope('all')).toBe(DEVICE_SCOPE_ALL)
    expect(parseDeviceScope(' ALL ')).toBe(DEVICE_SCOPE_ALL)
  })

  test('a hostId is kept', () => {
    expect(parseDeviceScope('desk')).toBe('desk')
    expect(parseDeviceScope(' peer-1 ')).toBe('peer-1')
  })

  test('an unknown or stale hostId is still the raw id', () => {
    expect(parseDeviceScope('gone-device')).toBe('gone-device')
    expect(parseDeviceScope('stale-host')).toBe('stale-host')
  })
})

describe('scopeRows', () => {
  const rows = [
    { hostId: 'desk', name: 'a' },
    { hostId: 'studio', name: 'b' },
    { hostId: 'desk', name: 'c' },
  ]

  test('all returns every row', () => {
    expect(scopeRows(rows, DEVICE_SCOPE_ALL)).toEqual(rows)
    expect(scopeRows(rows, '')).toEqual(rows)
  })

  test('one hostId filters', () => {
    expect(scopeRows(rows, 'desk')).toEqual([
      { hostId: 'desk', name: 'a' },
      { hostId: 'desk', name: 'c' },
    ])
    expect(scopeRows(rows, 'studio')).toEqual([{ hostId: 'studio', name: 'b' }])
    expect(scopeRows(rows, 'missing')).toEqual([])
  })

  test('empty list', () => {
    expect(scopeRows([], DEVICE_SCOPE_ALL)).toEqual([])
    expect(scopeRows([], 'desk')).toEqual([])
  })
})

describe('scopeOllamaModels', () => {
  const models = [
    {
      name: 'llama',
      locations: [
        { hostId: 'desk' },
        { hostId: 'studio' },
      ],
    },
    {
      name: 'peer-only',
      locations: [{ hostId: 'studio' }],
    },
    {
      name: 'self-only',
      locations: [{ hostId: 'desk' }],
    },
  ]

  test('all keeps every model', () => {
    expect(scopeOllamaModels(models, DEVICE_SCOPE_ALL)).toEqual(models)
  })

  test('ollama model with locations on peer kept/dropped correctly', () => {
    expect(scopeOllamaModels(models, 'desk').map((row) => row.name)).toEqual([
      'llama',
      'self-only',
    ])
    expect(scopeOllamaModels(models, 'studio').map((row) => row.name)).toEqual([
      'llama',
      'peer-only',
    ])
    expect(scopeOllamaModels(models, 'garage')).toEqual([])
  })

  test('empty list', () => {
    expect(scopeOllamaModels([], 'desk')).toEqual([])
  })
})

describe('scopeLibraryItems', () => {
  const items = [
    { slug: 'ubuntu', copies: [{ hostId: 'desk' }], sourceHostIds: ['desk'] },
    { slug: 'win', copies: [{ hostId: 'studio' }], sourceHostIds: ['studio'] },
    { slug: 'both', copies: [{ hostId: 'desk' }, { hostId: 'studio' }], sourceHostIds: ['desk', 'studio'] },
  ]

  test('all returns every item', () => {
    expect(scopeLibraryItems(items, DEVICE_SCOPE_ALL)).toEqual(items)
  })

  test('keeps copies on the selected Device', () => {
    expect(scopeLibraryItems(items, 'desk').map((row) => row.slug)).toEqual(['ubuntu', 'both'])
  })
})
