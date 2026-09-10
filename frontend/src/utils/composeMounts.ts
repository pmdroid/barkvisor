export type ComposeMount = {
  kind: 'bind' | 'volume'
  source: string
  target: string
}

export function parseComposeMounts(yaml: string): ComposeMount[] {
  if (!yaml.trim()) return []
  const out: ComposeMount[] = []
  for (const raw of yaml.split('\n')) {
    const line = raw.trim().replace(/^-\s+/, '')
    const unquoted = line.replace(/^["']|["']$/g, '')
    const m = unquoted.match(/^([^:]+):(\/[^:]+)(?::(?:ro|rw|z|Z))?$/)
    if (!m) continue
    const source = m[1].trim()
    const target = m[2].trim()
    if (!source || source.includes(' ')) continue
    const kind = source.startsWith('/') || source.startsWith('.') ? 'bind' : 'volume'
    out.push({ kind, source, target })
  }
  return out
}

export function mountsFromSharedPaths(paths: string[] | null | undefined): ComposeMount[] {
  if (!paths?.length) return []
  const out: ComposeMount[] = []
  for (const p of paths) {
    const i = p.lastIndexOf(':')
    if (i <= 0) continue
    const source = p.slice(0, i)
    const target = p.slice(i + 1)
    if (!target.startsWith('/')) continue
    const kind = source.startsWith('/') || source.startsWith('.') ? 'bind' : 'volume'
    out.push({ kind, source, target })
  }
  return out
}
