import type { SystemAbout } from '../api/types'

/** Fail closed: missing fields stay unknown. Never invent version or uptime. */
export function parseSystemAbout(data: unknown): SystemAbout | null {
  if (data == null || typeof data !== 'object') return null
  const row = data as Record<string, unknown>
  if (typeof row.version !== 'string' || row.version.trim() === '') return null
  if (typeof row.platform !== 'string' || row.platform.trim() === '') return null
  if (typeof row.hostArch !== 'string' || row.hostArch.trim() === '') return null
  if (typeof row.accelerator !== 'string' || row.accelerator.trim() === '') return null
  if (typeof row.processUptimeSeconds !== 'number' || !Number.isFinite(row.processUptimeSeconds)) {
    return null
  }
  const about: SystemAbout = {
    version: row.version,
    platform: row.platform,
    hostArch: row.hostArch,
    accelerator: row.accelerator,
    processUptimeSeconds: Math.trunc(row.processUptimeSeconds),
  }
  if (typeof row.displayName === 'string' && row.displayName.trim()) {
    about.displayName = row.displayName.trim()
  }
  return about
}
