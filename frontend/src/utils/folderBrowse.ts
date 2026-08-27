import type { DeviceApiTarget } from './homeDeviceApi'
import { deviceBrowsePath } from './homeDeviceApi'

export type FolderEntry = { name: string; path: string; isDirectory: boolean }

export function folderBrowseRequestPath(
  device?: DeviceApiTarget | null,
  source: 'system' | 'setup' = 'system',
): string {
  if (source === 'setup') return '/browse'
  return deviceBrowsePath(device)
}

export function folderBrowseParams(path: string): { path?: string } {
  return path ? { path } : {}
}

export function asFolderEntries(data: unknown): FolderEntry[] {
  const rows = Array.isArray(data)
    ? data
    : data && typeof data === 'object' && Array.isArray((data as { entries?: unknown }).entries)
      ? (data as { entries: unknown[] }).entries
      : []
  return rows.filter((row): row is FolderEntry => {
    if (!row || typeof row !== 'object') return false
    const item = row as FolderEntry
    return typeof item.name === 'string' && typeof item.path === 'string'
  })
}

export function folderHasRealEntries(entries: FolderEntry[]): boolean {
  return entries.some((row) => row.name !== '..')
}
