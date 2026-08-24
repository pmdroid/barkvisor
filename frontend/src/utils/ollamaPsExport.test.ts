import { describe, expect, test } from 'bun:test'
import {
  OLLAMA_PS_EXPORT_FILENAME,
  ollamaPsExportJSON,
  parseOllamaPsExport,
  serializeOllamaPs,
} from './ollamaPsExport'

const catalog = [
  {
    name: 'llama3:latest',
    size: 4_000,
    locations: [
      { hostId: 'desk', running: true, size: 4_000, sizeVRAM: 3_000 },
      { hostId: 'lab', running: false, size: 4_000 },
    ],
  },
]

describe('ollama /api/ps export', () => {
  test('serializes name size sizeVRAM running host per Device', () => {
    expect(serializeOllamaPs(catalog)).toEqual({
      models: [
        {
          name: 'llama3:latest',
          size: 4000,
          sizeVRAM: 3000,
          running: true,
          host: 'desk',
        },
        {
          name: 'llama3:latest',
          size: 4000,
          sizeVRAM: null,
          running: false,
          host: 'lab',
        },
      ],
    })
  })

  test('JSON round-trip keeps null sizeVRAM', () => {
    const json = ollamaPsExportJSON(catalog)
    const decoded = parseOllamaPsExport(json)
    expect(decoded.models[0]?.sizeVRAM).toBe(3000)
    expect(decoded.models[1]?.sizeVRAM).toBeNull()
    expect(decoded.models[1]?.host).toBe('lab')
    expect(json).toContain('"sizeVRAM": null')
    expect(json.endsWith('\n')).toBe(true)
    expect(OLLAMA_PS_EXPORT_FILENAME).toBe('ollama-ps.json')
  })

  test('empty catalog is models []', () => {
    expect(serializeOllamaPs([])).toEqual({ models: [] })
    expect(parseOllamaPsExport('{"models":[]}')).toEqual({ models: [] })
  })
})
