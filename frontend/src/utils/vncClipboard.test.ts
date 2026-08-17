import { describe, expect, test } from 'bun:test'
import { copyGuestText, readLocalClipboard, textFromPasteEvent } from './vncClipboard'

describe('vncClipboard', () => {
  test('reads plain text from a paste event', () => {
    const data = {
      getData: (type: string) => (type === 'text/plain' ? 'hello from host' : ''),
    }
    const event = { clipboardData: data } as unknown as ClipboardEvent
    expect(textFromPasteEvent(event)).toBe('hello from host')
  })

  test('falls back to text when text/plain is empty', () => {
    const data = {
      getData: (type: string) => (type === 'text' ? 'alt' : ''),
    }
    const event = { clipboardData: data } as unknown as ClipboardEvent
    expect(textFromPasteEvent(event)).toBe('alt')
  })

  test('returns empty string when clipboardData is missing', () => {
    const event = { clipboardData: null } as unknown as ClipboardEvent
    expect(textFromPasteEvent(event)).toBe('')
  })

  test('copyGuestText writes text and rejects empty', async () => {
    const written: string[] = []
    Object.defineProperty(globalThis, 'navigator', {
      configurable: true,
      value: {
        clipboard: {
          writeText: async (value: string) => {
            written.push(value)
          },
        },
      },
    })
    expect(await copyGuestText('')).toBe(false)
    expect(await copyGuestText('guest text')).toBe(true)
    expect(written).toEqual(['guest text'])
  })

  test('readLocalClipboard returns null when the API is missing', async () => {
    Object.defineProperty(globalThis, 'navigator', {
      configurable: true,
      value: {},
    })
    expect(await readLocalClipboard()).toBeNull()
  })
})
