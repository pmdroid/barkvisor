import { parse } from 'yaml'

export type ComposeMount = {
  kind: 'bind' | 'volume'
  source: string
  target: string
  readOnly: boolean
}

export function parseComposeMounts(yaml: string): ComposeMount[] {
  if (!yaml.trim()) return []
  let document
  try {
    document = parse(yaml)
  } catch {
    return []
  }
  const services = document?.services && typeof document.services === 'object'
    ? Object.values(document.services) : [document]
  const entries = typeof document === 'string' ? [document] : Array.isArray(document) ? document : services.flatMap((service: any) =>
    Array.isArray(service?.volumes) ? service.volumes : [],
  )
  const out: ComposeMount[] = []
  for (const entry of entries) {
    if (entry && typeof entry === 'object') {
      const { source, target, type, read_only } = entry
      if (typeof source !== 'string' || typeof target !== 'string' || !target.startsWith('/')) continue
      const kind = type ?? (source.startsWith('/') || source.startsWith('.') || source.startsWith('~') ? 'bind' : 'volume')
      if (kind !== 'bind' && kind !== 'volume') continue
      out.push({ kind, source, target, readOnly: read_only === true })
      continue
    }
    if (typeof entry !== 'string') continue
    const match = entry.match(/^([^:]+):(\/[^:]+)(?::(ro|rw|z|Z))?$/)
    if (!match) continue
    const source = match[1].trim()
    const target = match[2].trim()
    if (!source || !target) continue
    const kind = source.startsWith('/') || source.startsWith('.') ? 'bind' : 'volume'
    out.push({ kind, source, target, readOnly: match[3] === 'ro' })
  }
  return out
}

function mountKey(mount: ComposeMount): string {
  return `${mount.source}\0${mount.target}`
}

export function visibleAppMounts(input: {
  compose?: string | null
  sharedPaths?: string[] | null
}): ComposeMount[] {
  const fromCompose = parseComposeMounts(input.compose ?? '')
  const fromShared = mountsFromSharedPaths(input.sharedPaths)
  if (!fromCompose.length) return fromShared
  const seen = new Set(fromCompose.map(mountKey))
  return [...fromCompose, ...fromShared.filter((mount) => !seen.has(mountKey(mount)))]
}

export function stripTrailingSlash(path: string): string {
  if (path.length > 1 && path.endsWith('/')) return path.slice(0, -1)
  return path
}

export function isUnderManagedRoot(source: string, root: string): boolean {
  const src = stripTrailingSlash(source)
  const base = stripTrailingSlash(root)
  if (!src || !base) return false
  return src === base || src.startsWith(`${base}/`)
}

export function isManagedAppMount(mount: ComposeMount, roots: string[] | undefined): boolean {
  if (mount.kind === 'volume') return true
  return (roots ?? []).filter(Boolean).some((root) => isUnderManagedRoot(mount.source, root))
}

export function mountsFromSharedPaths(paths: string[] | null | undefined): ComposeMount[] {
  if (!paths?.length) return []
  const out: ComposeMount[] = []
  for (const p of paths) {
    let raw = p
    let readOnly = false
    if (raw.endsWith(':ro')) {
      readOnly = true
      raw = raw.slice(0, -3)
    } else if (raw.endsWith(':rw')) {
      raw = raw.slice(0, -3)
    }
    const i = raw.lastIndexOf(':')
    if (i <= 0) continue
    const source = raw.slice(0, i)
    const target = raw.slice(i + 1)
    if (!target.startsWith('/')) continue
    const kind = source.startsWith('/') || source.startsWith('.') ? 'bind' : 'volume'
    out.push({ kind, source, target, readOnly })
  }
  return out
}
