import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import {
  DEVICE_SCOPE_ALL,
  DEVICE_SCOPE_STORAGE_KEY,
  isDeviceScopeAll,
  parseDeviceScope,
} from '../utils/deviceScope'

function readStoredScope(): 'all' | string {
  try {
    return parseDeviceScope(localStorage.getItem(DEVICE_SCOPE_STORAGE_KEY))
  } catch {
    return DEVICE_SCOPE_ALL
  }
}

function writeStoredScope(hostId: string): void {
  try {
    localStorage.setItem(DEVICE_SCOPE_STORAGE_KEY, hostId)
  } catch {
    /* ignore quota / private mode */
  }
}

export const useDeviceScopeStore = defineStore('deviceScope', () => {
  const selectedHostId = ref<'all' | string>(readStoredScope())
  const isAll = computed(() => isDeviceScopeAll(selectedHostId.value))

  function select(hostId: string): void {
    const next = parseDeviceScope(hostId)
    selectedHostId.value = next
    writeStoredScope(next)
  }

  function forgetUnknownHost(hostIds: readonly string[]): void {
    if (isDeviceScopeAll(selectedHostId.value)) return
    if (hostIds.length === 0) return
    if (!hostIds.includes(selectedHostId.value)) select(DEVICE_SCOPE_ALL)
  }

  return {
    selectedHostId,
    isAll,
    select,
    forgetUnknownHost,
  }
})
