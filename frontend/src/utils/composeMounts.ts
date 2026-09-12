export type ComposeMount = {
  kind: 'bind' | 'volume'
  source: string
  target: string
  readOnly: boolean
}

export function parseComposeMounts(yaml: string): ComposeMount[] {
  if (!yaml.trim()) return []
  const out: ComposeMount[] = []
  for (const raw of yaml.split('\n')) {
    const line = raw.trim().replace(/^-\s+/, '')
    const unquoted = line.replace(/^["']|["']$/g, '')
    const m = unquoted.match(/^([^:]+):(\/[^:]+)(?::(ro|rw|z|Z))?$/)
    if (!m) continue
    const source = m[1].trim()
    const target = m[2].trim()
    if (!source || source.includes(' ')) continue
    const kind = source.startsWith('/') || source.startsWith('.') ? 'bind' : 'volume'
    out.push({ kind, source, target, readOnly: m[3] === 'ro' })
  }
  return out
}

export function visibleAppMounts(input: {
  compose?: string | null
  sharedPaths?: string[] | null
}): ComposeMount[] {
  const fromCompose = parseComposeMounts(input.compose ?? '')
  if (fromCompose.length) return fromCompose
  return mountsFromSharedPaths(input.sharedPaths)
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
