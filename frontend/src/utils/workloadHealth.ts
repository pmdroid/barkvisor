import type { VM, VMState, WorkloadHealth } from '../api/types'

export const WORKLOAD_HEALTH_VALUES: WorkloadHealth[] = [
  'unknown',
  'stopped',
  'starting',
  'running',
  'guest_ready',
  'degraded',
  'failed',
]

export function healthFromState(state: string): WorkloadHealth {
  switch (state) {
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

/** Apply an SSE VM state event so health pills do not keep a stale API health field. */
export function applyVMStateEvent(
  vm: Pick<VM, 'state' | 'health' | 'status'>,
  event: { state: string; error?: string | null },
): void {
  vm.state = event.state
  const derived = healthFromState(event.state)
  const previous = vm.health ?? vm.status?.health
  // SSE only carries lifecycle state. Keep API probe rollups while the guest
  // is still running so guest_ready/degraded do not flicker back to running.
  const keepProbeHealth =
    event.state === 'running' && (previous === 'guest_ready' || previous === 'degraded')
  const health = keepProbeHealth && previous ? previous : derived
  vm.health = health
  if (vm.status) {
    vm.status.state = event.state as VMState
    vm.status.health = health
    if (!keepProbeHealth || event.error !== undefined) {
      vm.status.healthError = event.error ?? null
    }
  }
}

export function vmHealth(vm: Pick<VM, 'health' | 'status' | 'state'>): WorkloadHealth {
  if (vm.health) return vm.health
  if (vm.status?.health) return vm.status.health
  return healthFromState(vm.state)
}

export function filterRowsByHealth<T extends { vm: Pick<VM, 'health' | 'status' | 'state'> }>(
  rows: T[],
  health: WorkloadHealth | 'all',
): T[] {
  if (health === 'all') return rows
  return rows.filter((row) => vmHealth(row.vm) === health)
}

export type VmListEmptyKind = 'none' | 'filtered' | 'table'

export function vmListEmptyKind(
  homeCount: number,
  visibleCount: number,
  filter: WorkloadHealth | 'all',
): VmListEmptyKind {
  if (visibleCount > 0) return 'table'
  if (homeCount > 0 && filter !== 'all') return 'filtered'
  return 'none'
}

export function healthLabel(health: WorkloadHealth): string {
  switch (health) {
    case 'guest_ready':
      return 'Guest ready'
    default:
      return health.charAt(0).toUpperCase() + health.slice(1)
  }
}

export function opsStatusLabel(health: WorkloadHealth): string {
  if (health === 'failed') return 'Failed'
  if (health === 'stopped' || health === 'unknown') return 'Stopped'
  return 'Running'
}

export function opsStatusClass(health: WorkloadHealth): 'ok' | 'bad' | 'off' {
  if (health === 'failed') return 'bad'
  if (health === 'stopped' || health === 'unknown') return 'off'
  return 'ok'
}

export function healthPillClass(health: WorkloadHealth): string {
  if (health === 'guest_ready') return 'guest_ready'
  return health
}
