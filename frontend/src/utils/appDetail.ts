import type { VM } from '../api/types'

const SECRET_RE = /PASSWORD|SECRET|TOKEN|KEY|CLAIM/i

export function isSecretEnvKey(key: string): boolean {
  return SECRET_RE.test(key)
}

export function composeProjectName(id: string): string {
  return `barkvisor-${id.replace(/-/g, '').toLowerCase()}`
}

export function parseRestartPolicy(yaml: string | null | undefined): string {
  const m = (yaml ?? '').match(/^\s*restart:\s*(\S+)/m)
  return m?.[1]?.replace(/^["']|["']$/g, '') || 'unless-stopped'
}

export function formatCreatedAgo(iso: string, now = Date.now()): string {
  const ms = now - Date.parse(iso)
  if (!Number.isFinite(ms) || ms < 0) return 'just now'
  const days = Math.floor(ms / 86_400_000)
  if (days === 1) return '1 day ago'
  if (days > 1) return `${days} days ago`
  const hours = Math.floor(ms / 3_600_000)
  if (hours === 1) return '1 hour ago'
  if (hours > 1) return `${hours} hours ago`
  const mins = Math.floor(ms / 60_000)
  if (mins <= 1) return 'just now'
  return `${mins} minutes ago`
}

export function formatUptime(iso: string, now = Date.now()): string {
  const ms = now - Date.parse(iso)
  if (!Number.isFinite(ms) || ms < 0) return '—'
  const days = Math.floor(ms / 86_400_000)
  const hours = Math.floor((ms % 86_400_000) / 3_600_000)
  if (days > 0) return `${days}d ${hours}h`
  const mins = Math.floor((ms % 3_600_000) / 60_000)
  if (hours > 0) return `${hours}h ${mins}m`
  if (mins > 0) return `${mins}m`
  return '<1m'
}

export function appToolbarSub(vm: VM, now = Date.now()): string {
  const bits: string[] = []
  const tagline = vm.description?.trim()
  if (tagline) bits.push(tagline)
  if (vm.createdAt) bits.push(`created ${formatCreatedAgo(vm.createdAt, now)}`)
  const catalog = appCatalogSource(vm)
  if (catalog) bits.push(`via ${catalog} catalog`)
  return bits.join(' · ')
}

export function appClassLabel(vm: VM): string | null {
  const raw = (vm.workloadClass || '').toLowerCase()
  if (raw === 'house') return 'House'
  if (raw === 'agent') return 'Agent'
  return raw ? raw : null
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

export function buildEnvSavePayload(
  current: Record<string, string>,
  editable: Record<string, string>,
): Record<string, string> {
  const next: Record<string, string> = {}
  for (const [k, v] of Object.entries(current)) {
    if (isSecretEnvKey(k)) next[k] = v
  }
  for (const [k, v] of Object.entries(editable)) {
    if (!isSecretEnvKey(k)) next[k] = v
  }
  return next
}

export function ingressPrefixPath(id: string): string {
  return `/go/${id}/`
}

export function appIngressState(vm: VM): {
  enabled: boolean
  mode: 'prefix' | 'direct'
  path: string
  reason: string
} {
  const ingress = vm.ingress ?? vm.spec?.spec?.ingress
  const enabled = ingress?.enabled !== false
  const override = (ingress?.mode || '').toLowerCase()
  const labels = vm.spec?.metadata?.labels
  const proxy = (labels?.['ui.proxy'] || labels?.proxy || '').toLowerCase()
  const name = vm.name.toLowerCase()
  const catalogDirect = /plex|immich|jellyfin|code-server|nextcloud/.test(name)
  let mode: 'prefix' | 'direct'
  if (override === 'prefix' || override === 'direct') mode = override
  else if (proxy === 'prefix' || proxy === 'direct') mode = proxy
  else mode = catalogDirect ? 'direct' : 'prefix'
  const path = ingressPrefixPath(vm.id)
  if (!enabled) {
    return {
      enabled: false,
      mode,
      path,
      reason: 'Ingress is off. Open the app on its published LAN port.',
    }
  }
  if (mode === 'direct') {
    return {
      enabled: true,
      mode,
      path,
      reason: 'Direct: the app is reached on its published LAN port, not through BarkVisor.',
    }
  }
  return {
    enabled: true,
    mode,
    path,
    reason: `Prefix: open this app at ${path} on the Device.`,
  }
}

export function appIngressMode(vm: VM): { direct: boolean; label: string; reason: string } {
  const state = appIngressState(vm)
  return {
    direct: !state.enabled || state.mode === 'direct',
    label: !state.enabled ? 'Off' : state.mode === 'direct' ? 'Direct' : 'Prefix',
    reason: state.reason,
  }
}
