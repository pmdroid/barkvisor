import { describe, expect, test } from 'bun:test'
import { librarySpaceCopy } from './librarySpace'

describe('librarySpaceCopy', () => {
  test('humanizes free of total with formatBytes', () => {
    expect(librarySpaceCopy(500e9, 12.3e9)).toBe('12.3 GB free of 500.0 GB')
    expect(librarySpaceCopy(1e9, 512e6)).toBe('512.0 MB free of 1.0 GB')
  })

  test('unknown stats are not zeros pretending to be capacity', () => {
    expect(librarySpaceCopy(null, null)).toBeNull()
    expect(librarySpaceCopy(undefined, undefined)).toBeNull()
    expect(librarySpaceCopy(null, 12.3e9)).toBeNull()
    expect(librarySpaceCopy(500e9, null)).toBeNull()
    expect(librarySpaceCopy(0, 0)).toBeNull()
    expect(librarySpaceCopy(0, 100)).toBeNull()
    expect(librarySpaceCopy(Number.NaN, 1e9)).toBeNull()
    expect(librarySpaceCopy(1e9, Number.NaN)).toBeNull()
  })

  test('nonsensical free greater than total is unknown', () => {
    expect(librarySpaceCopy(100, 200)).toBeNull()
  })

  test('a full volume with a known total is still shown', () => {
    expect(librarySpaceCopy(1e9, 0)).toBe('0 B free of 1.0 GB')
  })
})
