import type { VM, WorkloadHealth } from '../api/types'

export const WORKLOAD_HEALTH_VALUES: WorkloadHealth[] = [
  'unknown',
  'stopped',
  'starting',
  'running',
  'guest_ready',
  'degraded',
  'failed',
]

export function vmHealth(vm: Pick<VM, 'health' | 'status' | 'state'>): WorkloadHealth {
  if (vm.health) return vm.health
  if (vm.status?.health) return vm.status.health
  switch (vm.state) {
    case 'error':
      return 'failed'
    case 'starting':
    case 'provisioning':
      return 'starting'
    case 'running':
    case 'stopping':
      return 'running'
    case 'stopped':
    case 'deleting':
      return 'stopped'
    default:
      return 'unknown'
  }
}

export function healthLabel(health: WorkloadHealth): string {
  switch (health) {
    case 'guest_ready':
      return 'Guest ready'
    default:
      return health.charAt(0).toUpperCase() + health.slice(1)
  }
}

export function healthPillClass(health: WorkloadHealth): string {
  if (health === 'guest_ready') return 'guest_ready'
  return health
}
