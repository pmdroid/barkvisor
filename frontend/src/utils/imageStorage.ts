export function imageStorageLine(opts: {
  path?: string | null
  hostLabel?: string | null
}): string {
  const path = opts.path?.trim() ?? ''
  const host = opts.hostLabel?.trim() ?? ''
  if (host && path) return `${host} · ${path}`
  return path || host
}
