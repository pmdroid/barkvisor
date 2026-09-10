import type { VM } from '../api/types'
import { isSelfDevice, type DeviceApiTarget } from './homeDeviceApi'

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

export function usesPrefixIngress(vm: Pick<VM, 'ingress' | 'spec'>): boolean {
  const ingress = vm.ingress ?? vm.spec?.spec?.ingress
  if (ingress?.enabled === false) return false
  const mode = (ingress?.mode || '').toLowerCase()
  return mode === 'prefix'
}

export function appOpenUrl(
  vm: Pick<VM, 'id' | 'openUrl' | 'publishedPorts' | 'ingress' | 'spec'>,
  device?: DeviceApiTarget | null,
): string | null {
  if (usesPrefixIngress(vm)) {
    const id = encodeURIComponent(vm.id)
    if (device && !isSelfDevice(device)) {
      return `/home/devices/${encodeURIComponent(device.hostId)}/go/${id}/`
    }
    return `/go/${id}/`
  }
  return firstOpenUrl(vm)
}
