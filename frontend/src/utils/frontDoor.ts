import { ref } from 'vue'
import type { AuthMode } from './authMode'

export const frontDoorBypassed = ref(false)
export const frontDoorAuthMode = ref<AuthMode>('secure')
export const frontDoorProxied = ref(false)

export function applyFrontDoorBypass(mode: AuthMode, proxied = false) {
  frontDoorBypassed.value = mode === 'loopback' || mode === 'disabled'
  frontDoorAuthMode.value = mode
  frontDoorProxied.value = proxied
}

export function clearFrontDoorBypass() {
  frontDoorBypassed.value = false
  frontDoorAuthMode.value = 'secure'
  frontDoorProxied.value = false
}
