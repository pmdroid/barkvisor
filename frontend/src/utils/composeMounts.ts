export type ComposeMount = {
  kind: 'bind' | 'volume'
  source: string
  target: string
}

export function parseComposeMounts(yaml: string): ComposeMount[] {
  if (!yaml.trim()) return []
  const out: ComposeMount[] = []
  for (const raw of yaml.split('\n')) {
    const line = raw.trim()
    const m = line.match(/^- (?:type:\s*)?(?:bind\s+)?["']?([^:"'\s]+):([^:"'\s]+)(?::[a-z,]+)?["']?$/)
    if (!m) continue
    const source = m[1]
    const target = m[2]
    if (!source || !target || !target.startsWith('/')) continue
    const kind = source.startsWith('/') || source.startsWith('.') ? 'bind' : 'volume'
    out.push({ kind, source, target })
  }
  return out
}
