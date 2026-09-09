export function firstPasswordFromLine(line: string): string | null {
  const lower = line.toLowerCase()
  if (
    !lower.includes('temporary password is provided for this session')
    && !lower.includes('webui administrator password was not set')
  ) {
    return null
  }
  const colon = line.lastIndexOf(':')
  if (colon < 0) return null
  const token = line.slice(colon + 1).trim().split(/\s+/)[0] ?? ''
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
