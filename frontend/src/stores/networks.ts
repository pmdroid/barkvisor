import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import api from '../api/client'
import type { Network, NetworkModeName } from '../api/types'
import { apiErrorMessage } from '../api/errors'

export type NetworkWriteBody = {
  name: string
  mode: NetworkModeName
  bridge?: string
  dnsServer?: string
}

export const useNetworkStore = defineStore('networks', () => {
  const networks = ref<Network[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  const byId = computed(() => {
    const map: Record<string, Network> = {}
    for (const n of networks.value) map[n.id] = n
    return map
  })

  const defaultNAT = computed(
    () =>
      networks.value.find(n => n.mode === 'nat' && n.isDefault)
      ?? networks.value.find(n => n.mode === 'nat')
      ?? null,
  )

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      const { data } = await api.get<Network[]>('/networks')
      networks.value = data
    } catch (e: unknown) {
      error.value = apiErrorMessage(e, 'Failed to load networks')
    } finally {
      loading.value = false
    }
  }

  async function create(body: NetworkWriteBody): Promise<Network> {
    const { data } = await api.post<Network>('/networks', body)
    networks.value.push(data)
    return data
  }

  async function update(id: string, body: Partial<NetworkWriteBody>): Promise<Network> {
    const { data } = await api.patch<Network>(`/networks/${id}`, body)
    const idx = networks.value.findIndex(n => n.id === id)
    if (idx >= 0) networks.value[idx] = data
    else networks.value.push(data)
    return data
  }

  async function remove(id: string) {
    await api.delete(`/networks/${id}`)
    networks.value = networks.value.filter(n => n.id !== id)
  }

  function getById(id: string | null | undefined): Network | undefined {
    if (!id) return undefined
    return byId.value[id]
  }

  return {
    networks,
    loading,
    error,
    byId,
    defaultNAT,
    fetchAll,
    create,
    update,
    remove,
    getById,
  }
})
