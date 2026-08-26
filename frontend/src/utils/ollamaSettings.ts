import type { OllamaSettingsUpdate } from '../api/types'

/**
 * PUT body for a new upstream key. Null when host or draft is blank so JSON
 * omits `apiKey`. A present empty string would clear the stored key.
 */
export function ollamaSettingsKeyBody(
  hostId: string,
  apiKeyDraft: string,
): OllamaSettingsUpdate | null {
  const host = hostId.trim()
  const apiKey = apiKeyDraft.trim()
  if (!host || !apiKey) return null
  return { hostId: host, apiKey }
}

export type InferenceBackendName = 'ollama' | 'unsloth'

export function parseInferenceBackend(raw?: string | null): InferenceBackendName {
  return (raw ?? '').trim().toLowerCase() === 'unsloth' ? 'unsloth' : 'ollama'
}

export function ollamaSettingsBackendBody(
  hostId: string,
  backend: string,
): OllamaSettingsUpdate | null {
  const host = hostId.trim()
  if (!host) return null
  return { hostId: host, backend: parseInferenceBackend(backend) }
}
