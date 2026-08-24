import { defineStore } from 'pinia'
import { computed, ref } from 'vue'
import api from '../api/client'
import type {
  OllamaHomeCatalog,
  OllamaHostSettings,
  OllamaSettingsSnapshot,
  OllamaSettingsUpdate,
  OllamaTaskAccepted,
} from '../api/types'

export const useOllamaStore = defineStore('ollama', () => {
  const catalog = ref<OllamaHomeCatalog | null>(null)
  const settings = ref<OllamaSettingsSnapshot | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)
  let fetchSeq = 0

  const anyReachable = computed(() => catalog.value?.anyReachable === true)
  const models = computed(() => catalog.value?.models ?? [])
  const devices = computed(() => catalog.value?.devices ?? [])

  async function fetchCatalog(): Promise<void> {
    const seq = ++fetchSeq
    loading.value = true
    try {
      const { data } = await api.get<OllamaHomeCatalog>('/home/ollama/models')
      if (seq !== fetchSeq) return
      catalog.value = data
      error.value = null
    } catch (err) {
      if (seq !== fetchSeq) return
      catalog.value = null
      error.value = err instanceof Error ? err.message : 'Unable to load Ollama'
    } finally {
      if (seq === fetchSeq) loading.value = false
    }
  }

  async function fetchSettings(): Promise<void> {
    try {
      const { data } = await api.get<OllamaSettingsSnapshot>('/home/ollama/settings')
      settings.value = data
    } catch {
      settings.value = null
    }
  }

  function hostSettings(hostId: string): OllamaHostSettings | undefined {
    return settings.value?.hosts.find((row) => row.hostId === hostId)
  }

  async function pull(name: string, hostId?: string): Promise<OllamaTaskAccepted> {
    const { data } = await api.post<OllamaTaskAccepted>('/home/ollama/pull', { name, hostId })
    return data
  }

  async function start(name: string, hostId?: string): Promise<void> {
    await api.post('/home/ollama/start', hostId ? { name, hostId } : { name })
  }

  async function stop(name: string, hostId?: string): Promise<void> {
    await api.post('/home/ollama/stop', { name, hostId })
  }

  async function saveSettings(payload: OllamaSettingsUpdate): Promise<void> {
    const { data } = await api.put<OllamaSettingsSnapshot>('/home/ollama/settings', payload)
    settings.value = data
  }

  return {
    catalog,
    settings,
    loading,
    error,
    anyReachable,
    models,
    devices,
    fetchCatalog,
    fetchSettings,
    hostSettings,
    pull,
    start,
    stop,
    saveSettings,
  }
})
