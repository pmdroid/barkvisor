import { describe, expect, test } from 'bun:test'
import { imageProgressPercent } from './imageProgress'

describe('imageProgressPercent', () => {
  test('nullish or non-numeric percent is indeterminate', () => {
    expect(imageProgressPercent(undefined)).toBe(null)
    expect(imageProgressPercent(null)).toBe(null)
    expect(imageProgressPercent({})).toBe(null)
    expect(imageProgressPercent({ percent: null })).toBe(null)
    expect(imageProgressPercent({ percent: Number.NaN })).toBe(null)
  })

  test('returns 0-100 from the server scale', () => {
    expect(imageProgressPercent({ percent: 0 })).toBe(0)
    expect(imageProgressPercent({ percent: 47 })).toBe(47)
    expect(imageProgressPercent({ percent: 100 })).toBe(100)
  })

  test('does not treat 0-1 values as fractions of 100', () => {
    expect(imageProgressPercent({ percent: 0.4 })).toBe(0)
    expect(imageProgressPercent({ percent: 1 })).toBe(1)
  })

  test('clamps out of range values', () => {
    expect(imageProgressPercent({ percent: -5 })).toBe(0)
    expect(imageProgressPercent({ percent: 150 })).toBe(100)
  })
})
