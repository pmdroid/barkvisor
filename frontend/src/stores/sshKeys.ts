import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import api from '../api/client'
import type { SSHKey } from '../api/types'
import { HOME_SSH_KEYS_PATH } from '../utils/homeSSHKey'

/** Home SSH public keys (This Device / Home). Workers do not own this table. */
export const useSSHKeyStore = defineStore('sshKeys', () => {
  const keys = ref<SSHKey[]>([])
  const loading = ref(false)

  const defaultKey = computed(() => keys.value.find(k => k.isDefault) ?? null)

  let fetchSeq = 0

  async function fetchAll() {
    const seq = ++fetchSeq
    loading.value = true
    try {
      const { data } = await api.get(HOME_SSH_KEYS_PATH)
      if (seq !== fetchSeq) return
      keys.value = data
    } finally {
      if (seq === fetchSeq) loading.value = false
    }
  }

  async function create(name: string, publicKey: string): Promise<SSHKey> {
    const { data } = await api.post(HOME_SSH_KEYS_PATH, { name, publicKey })
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
