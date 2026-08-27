import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import type { PasskeyCredential } from '../api/types'
import { createPasskey } from '../utils/webauthn'

export const usePasskeyStore = defineStore('passkeys', () => {
  const keys = ref<PasskeyCredential[]>([])
  const loading = ref(false)

  async function fetchAll() {
    loading.value = true
    try {
      const { data } = await api.get<PasskeyCredential[]>('/auth/passkeys')
      keys.value = data
    } finally {
      loading.value = false
    }
  }

  async function add(name?: string): Promise<PasskeyCredential> {
    const { data: begin } = await api.post<{ sessionId: string; publicKey: Record<string, unknown> }>(
      '/auth/passkeys/register/begin',
      name ? { name } : {},
    )
    const credential = await createPasskey(begin.publicKey)
    const { data } = await api.post<PasskeyCredential>('/auth/passkeys/register/finish', {
      sessionId: begin.sessionId,
      credential,
      name,
    })
    keys.value.unshift(data)
    return data
  }

  async function remove(id: string) {
    await api.delete(`/auth/passkeys/${id}`)
    keys.value = keys.value.filter((k) => k.id !== id)
  }

  return { keys, loading, fetchAll, add, remove }
})
