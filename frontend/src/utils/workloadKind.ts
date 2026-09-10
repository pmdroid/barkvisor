import type { VM } from '../api/types'

export function isApplicationWorkload(vm: Pick<VM, 'kind' | 'spec'>): boolean {
  return vm.kind === 'Application' || vm.spec?.kind === 'Application'
}

export function workloadKindLabel(vm: Pick<VM, 'kind' | 'spec'>): 'VM' | 'App' {
  return isApplicationWorkload(vm) ? 'App' : 'VM'
}

export function firstOpenUrl(vm: Pick<VM, 'openUrl' | 'publishedPorts'>): string | null {
  if (vm.openUrl) return vm.openUrl
  const port = vm.publishedPorts?.find((row) => row.url)
  return port?.url ?? null
}
