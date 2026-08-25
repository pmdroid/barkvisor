import { describe, expect, test } from 'bun:test'
import { formatCores, formatLogClock, formatMemoryMB, formatPortForwards, formatStorageSize, formatTemperatureC, formatVolumeUsed, parseLogDate } from './format'

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

describe('formatStorageSize', () => {
  test('gigabytes and terabytes', () => {
    expect(formatStorageSize(1073741824)).toBe('1 GB')
    expect(formatStorageSize(240 * 1073741824)).toBe('240 GB')
    expect(formatStorageSize(1099511627776)).toBe('1 TB')
  })
})

describe('formatVolumeUsed', () => {
  test('used over total', () => {
    expect(formatVolumeUsed(1099511627776, 1099511627776 - 240 * 1073741824)).toBe('240 GB / 1 TB')
  })
})

describe('formatMemoryMB', () => {
  test('whole gigabytes drop the decimal', () => {
    expect(formatMemoryMB(16384)).toBe('16 GB')
    expect(formatMemoryMB(1024)).toBe('1 GB')
  })

  test('megabytes stay in MB', () => {
    expect(formatMemoryMB(512)).toBe('512 MB')
  })
})

describe('formatCores', () => {
  test('singular and plural', () => {
    expect(formatCores(1)).toBe('1 core')
    expect(formatCores(4)).toBe('4 cores')
  })
})

describe('formatPortForwards', () => {
  test('empty is an em dash', () => {
    expect(formatPortForwards([])).toBe('—')
    expect(formatPortForwards(null)).toBe('—')
  })

  test('renders protocol host → guest', () => {
    expect(formatPortForwards([{ protocol: 'tcp', hostPort: 3389, guestPort: 3389 }])).toBe('tcp 3389 → 3389')
  })
})

describe('parseLogDate', () => {
  test('unix seconds', () => {
    const d = parseLogDate('1720000000')
    expect(d).not.toBe(null)
    expect(d!.getTime()).toBe(1720000000 * 1000)
  })

  test('iso strings', () => {
    const d = parseLogDate('2026-08-25T12:05:14.002Z')
    expect(d).not.toBe(null)
    expect(formatLogClock('2026-08-25T12:05:14.002Z')).toMatch(/^\d{2}:\d{2}:\d{2}\.\d{3}$/)
  })

  test('invalid is not Invalid Date', () => {
    expect(parseLogDate('')).toBe(null)
    expect(parseLogDate('nope')).toBe(null)
    expect(formatLogClock('')).toBe('—')
  })
})
