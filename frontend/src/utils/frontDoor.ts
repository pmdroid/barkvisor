import { ref } from 'vue'
import type { AuthMode } from './authMode'

export const frontDoorBypassed = ref(false)
export const frontDoorAuthMode = ref<AuthMode>('secure')

export function applyFrontDoorBypass(mode: AuthMode) {
  frontDoorBypassed.value = mode === 'loopback' || mode === 'disabled'
  frontDoorAuthMode.value = mode
}

export function clearFrontDoorBypass() {
  frontDoorBypassed.value = false
  frontDoorAuthMode.value = 'secure'
}
