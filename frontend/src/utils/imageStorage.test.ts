import { describe, expect, test } from 'bun:test'
import { imageStorageLine } from './imageStorage'

describe('imageStorageLine', () => {
  test('joins device label and path', () => {
    expect(imageStorageLine({ hostLabel: 'Garage', path: '/var/lib/barkvisor/images/a.iso' }))
      .toBe('Garage · /var/lib/barkvisor/images/a.iso')
  })

  test('path only', () => {
    expect(imageStorageLine({ path: '/data/images/a.iso' })).toBe('/data/images/a.iso')
  })

  test('host only', () => {
    expect(imageStorageLine({ hostLabel: 'Desk' })).toBe('Desk')
  })

  test('empty', () => {
    expect(imageStorageLine({})).toBe('')
  })
})
