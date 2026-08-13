import { describe, expect, test } from 'bun:test'
import { formatTemperatureC } from './format'

describe('formatTemperatureC', () => {
  test('missing sensors are not rendered as 0°C', () => {
    expect(formatTemperatureC(null)).toBe(null)
    expect(formatTemperatureC(undefined)).toBe(null)
    expect(formatTemperatureC(Number.NaN)).toBe(null)
  })

  test('real readings including zero stay numeric', () => {
    expect(formatTemperatureC(0)).toBe('0°C')
    expect(formatTemperatureC(47.6)).toBe('48°C')
    expect(formatTemperatureC(31)).toBe('31°C')
  })
})
