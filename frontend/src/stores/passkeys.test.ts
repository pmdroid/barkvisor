import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import { usePasskeyStore } from './passkeys'

const originalGet = api.get
const originalPost = api.post
const originalDelete = api.delete

describe('passkey store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
    api.post = originalPost
    api.delete = originalDelete
  })

  test('fetchAll stores the list', async () => {
    api.get = mock(() =>
      Promise.resolve({
        data: [
          {
            id: 'pk-1',
            name: 'Laptop',
            createdAt: '2026-01-01T00:00:00Z',
            lastUsedAt: null,
            credentialId: 'abc',
          },
        ],
      }),
    ) as typeof api.get
    const store = usePasskeyStore()
    await store.fetchAll()
    expect(store.keys).toHaveLength(1)
    expect(store.keys[0]?.name).toBe('Laptop')
  })

  test('remove drops the local row', async () => {
    const store = usePasskeyStore()
    store.keys = [
      {
        id: 'pk-1',
        name: 'Laptop',
        createdAt: '2026-01-01T00:00:00Z',
        lastUsedAt: null,
        credentialId: 'abc',
      },
    ]
    api.delete = mock(() => Promise.resolve({ status: 204 })) as typeof api.delete
    await store.remove('pk-1')
    expect(store.keys).toHaveLength(0)
  })
})
