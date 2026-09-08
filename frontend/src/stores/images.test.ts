import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import { useImageStore } from './images'

const originalDelete = api.delete

describe('image store local delete', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.delete = originalDelete
  })

  test('remove DELETEs local /images/:id', async () => {
    const del = mock((url: string) => {
      expect(url).toBe('/images/local-img')
      return Promise.resolve({ data: {} })
    })
    api.delete = del as typeof api.delete
    const store = useImageStore()
    store.images = [{
      id: 'local-img',
      name: 'ubuntu.iso',
      imageType: 'iso',
      arch: 'x86_64',
      status: 'ready',
      sizeBytes: 1,
      sourceUrl: null,
      error: null,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    }]
    await store.remove('local-img')
    expect(del.mock.calls.map((c) => c[0])).toEqual(['/images/local-img'])
    expect(store.images).toEqual([])
  })
})
