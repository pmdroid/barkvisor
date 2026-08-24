import type { OllamaCatalogModel } from '../api/types'
import { saveBlob } from './diagnosticsBundle'

export const OLLAMA_PS_EXPORT_FILENAME = 'ollama-ps.json'

/** Point-in-time `/api/ps` fields already on the Home catalog. */
export interface OllamaPsStat {
  name: string
  size: number | null
  sizeVRAM: number | null
  running: boolean
  host: string
}

export interface OllamaPsExport {
  models: OllamaPsStat[]
}

type CatalogRow = Pick<OllamaCatalogModel, 'name' | 'size' | 'sizeVRAM' | 'locations'>

/** One row per Device location. Same JSON as Console ShareLink. */
export function serializeOllamaPs(models: CatalogRow[]): OllamaPsExport {
  return {
    models: models.flatMap((model) =>
      model.locations.map((loc) => ({
        name: model.name,
        size: loc.size ?? model.size ?? null,
        sizeVRAM: loc.sizeVRAM ?? (loc.running ? (model.sizeVRAM ?? null) : null),
        running: loc.running,
        host: loc.hostId,
      })),
    ),
  }
}

export function ollamaPsExportJSON(models: CatalogRow[]): string {
  return `${JSON.stringify(serializeOllamaPs(models), null, 2)}\n`
}

export function parseOllamaPsExport(json: string): OllamaPsExport {
  const parsed: unknown = JSON.parse(json)
  if (!parsed || typeof parsed !== 'object' || !('models' in parsed)) {
    throw new Error('Ollama stats JSON must be { models: [...] }')
  }
  const models = (parsed as { models: unknown }).models
  if (!Array.isArray(models)) {
    throw new Error('Ollama stats JSON models must be an array')
  }
  return {
    models: models.map((row) => {
      if (!row || typeof row !== 'object') {
        throw new Error('Ollama stats row must be an object')
      }
      const item = row as Record<string, unknown>
      if (typeof item.name !== 'string' || typeof item.host !== 'string') {
        throw new Error('Ollama stats row needs name and host')
      }
      if (typeof item.running !== 'boolean') {
        throw new Error('Ollama stats row needs running')
      }
      return {
        name: item.name,
        size: typeof item.size === 'number' ? item.size : null,
        sizeVRAM: typeof item.sizeVRAM === 'number' ? item.sizeVRAM : null,
        running: item.running,
        host: item.host,
      }
    }),
  }
}

export function downloadOllamaPsExport(models: CatalogRow[]): void {
  const blob = new Blob([ollamaPsExportJSON(models)], { type: 'application/json' })
  saveBlob(blob, OLLAMA_PS_EXPORT_FILENAME)
}
