import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import api from '../api/client'
import type { SSHKey } from '../api/types'

export const useSSHKeyStore = defineStore('sshKeys', () => {
  const keys = ref<SSHKey[]>([])
  const loading = ref(false)

  const defaultKey = computed(() => keys.value.find(k => k.isDefault) ?? null)

  async function fetchAll() {
    loading.value = true
    try {
      const { data } = await api.get('/ssh-keys')
      keys.value = data
    } finally {
      loading.value = false
    }
  }

  async function create(name: string, publicKey: string): Promise<SSHKey> {
    const { data } = await api.post('/ssh-keys', { name, publicKey })
    keys.value.unshift(data)
    return data
  }

  async function setDefault(id: string) {
    const { data } = await api.post(`/ssh-keys/${id}/default`)
    // Update local state
    keys.value = keys.value.map(k => ({ ...k, isDefault: k.id === id }))
    return data
  }

  async function remove(id: string) {
    await api.delete(`/ssh-keys/${id}`)
    keys.value = keys.value.filter(k => k.id !== id)
  }

  return { keys, loading, defaultKey, fetchAll, create, setDefault, remove }
})
