import type { VM } from '../api/types'

const SECRET_RE = /PASSWORD|SECRET|TOKEN|KEY|CLAIM/i

export function isSecretEnvKey(key: string): boolean {
  return SECRET_RE.test(key)
}

export function appCatalogSource(vm: VM): string | null {
  const labels = vm.spec?.metadata?.labels
  const raw = labels?.['catalog-source'] || labels?.catalog || labels?.source
  if (!raw) return null
  if (raw === 'linuxserver') return 'LinuxServer'
  if (raw === 'bigbear' || raw === 'big-bear') return 'Big Bear'
  return raw
}

export function appEnvSummary(vm: VM): { count: number; secrets: number } {
  const env = vm.spec?.spec?.env ?? {}
  const keys = Object.keys(env)
  return {
    count: keys.length,
    secrets: keys.filter((k) => SECRET_RE.test(k)).length,
  }
}

export function appIngressMode(vm: VM): { direct: boolean; label: string; reason: string } {
  const labels = vm.spec?.metadata?.labels
  const proxy = (labels?.['ui.proxy'] || labels?.proxy || '').toLowerCase()
  const catalog = appCatalogSource(vm)
  const name = vm.name.toLowerCase()
  const directCatalog = /plex|immich|jellyfin|code-server|nextcloud/.test(name)
  const direct = proxy === 'direct' || (proxy !== 'prefix' && directCatalog)
  if (direct) {
    return {
      direct: true,
      label: 'Direct',
      reason: catalog
        ? `${vm.name} is a catalog-direct application — it binds its own port and is reached directly.`
        : 'This app is reached on its published LAN port, not through BarkVisor ingress.',
    }
  }
  return {
    direct: false,
    label: 'Prefix',
    reason: 'Open this app through BarkVisor at /go/<id>/ on the Device.',
  }
}
