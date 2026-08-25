import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { DEVICE_SCOPE_ALL, DEVICE_SCOPE_STORAGE_KEY } from '../utils/deviceScope'
import { useDeviceScopeStore } from './deviceScope'

const memory = new Map<string, string>()
Object.defineProperty(globalThis, 'localStorage', {
  configurable: true,
  value: {
    getItem(key: string) {
      return memory.has(key) ? memory.get(key)! : null
    },
    setItem(key: string, value: string) {
      memory.set(key, String(value))
    },
    removeItem(key: string) {
      memory.delete(key)
    },
    clear() {
      memory.clear()
    },
  },
})

describe('deviceScope store', () => {
  beforeEach(() => {
    localStorage.clear()
    setActivePinia(createPinia())
  })

  afterEach(() => {
    localStorage.clear()
  })

  test('defaults to all', () => {
    const store = useDeviceScopeStore()
    expect(store.selectedHostId).toBe(DEVICE_SCOPE_ALL)
    expect(store.isAll).toBe(true)
  })

  test('select persists and reloads', () => {
    const store = useDeviceScopeStore()
    store.select('desk')
    expect(store.selectedHostId).toBe('desk')
    expect(store.isAll).toBe(false)
    expect(localStorage.getItem(DEVICE_SCOPE_STORAGE_KEY)).toBe('desk')

    setActivePinia(createPinia())
    const again = useDeviceScopeStore()
    expect(again.selectedHostId).toBe('desk')
    expect(again.isAll).toBe(false)
  })

  test('select all writes all', () => {
    const store = useDeviceScopeStore()
    store.select('desk')
    store.select(DEVICE_SCOPE_ALL)
    expect(store.selectedHostId).toBe(DEVICE_SCOPE_ALL)
    expect(store.isAll).toBe(true)
    expect(localStorage.getItem(DEVICE_SCOPE_STORAGE_KEY)).toBe(DEVICE_SCOPE_ALL)
  })

  test('reads a stored hostId on first use', () => {
    localStorage.setItem(DEVICE_SCOPE_STORAGE_KEY, 'studio')
    const store = useDeviceScopeStore()
    expect(store.selectedHostId).toBe('studio')
    expect(store.isAll).toBe(false)
  })
})
