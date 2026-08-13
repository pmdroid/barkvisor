import type { VM, VMRuntimeBackend } from '../api/types'

export function vmBackend(
  vm: Pick<VM, 'status'> | { status?: { backend?: VMRuntimeBackend | null } | null },
): VMRuntimeBackend | null {
  return vm.status?.backend ?? null
}

export function acceleratorLabel(accel: string | null | undefined): string {
  switch ((accel || '').toLowerCase()) {
    case 'hvf':
      return 'HVF'
    case 'kvm':
      return 'KVM'
    case 'tcg':
      return 'TCG'
    default:
      return accel || 'unknown'
  }
}

/** List badge only when the workload is not using native hardware acceleration. */
export function listBackendBadge(
  backend: VMRuntimeBackend | null | undefined,
): { label: string; title: string } | null {
  if (!backend?.emulated) return null
  const label = backend.accelerator === 'tcg' ? 'TCG' : 'Emulated'
  return {
    label,
    title: backend.warning || 'Software emulation — slower than hardware acceleration',
  }
}
