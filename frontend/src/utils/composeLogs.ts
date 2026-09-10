export function firstPasswordFromLine(line: string): string | null {
  const lower = line.toLowerCase()
  const marker = 'this session:'
  const at = lower.indexOf(marker)
  if (at < 0) return null
  const token = line.slice(at + marker.length).trim().split(/\s+/)[0] ?? ''
  return token || null
}

export function firstPasswordFromLogs(lines: string[]): string | null {
  for (const line of lines) {
    const value = firstPasswordFromLine(line)
    if (value) return value
  }
  return null
}

export function isFirstPasswordLine(line: string): boolean {
  return firstPasswordFromLine(line) !== null
}

export function shortDigest(value: string | null | undefined): string {
  if (!value) return '—'
  const digest = value.includes('@') ? value.slice(value.lastIndexOf('@') + 1) : value
  if (digest.length <= 19) return digest
  return `${digest.slice(0, 19)}…`
}
