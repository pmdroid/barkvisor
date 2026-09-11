import { useAuthStore } from '../stores/auth'
import type { AuthMode } from './authMode'

export function syncFrontDoorSession(mode: AuthMode) {
  const auth = useAuthStore()
  if (mode === 'secure') auth.clearBypass()
  else auth.applyBypass(mode)
}
