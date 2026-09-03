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

export function folderMkdirRequestPath(
  device?: DeviceApiTarget | null,
  source: 'system' | 'setup' = 'system',
): string {
  if (source === 'setup') return '/browse/mkdir'
  const browse = folderBrowseRequestPath(device, source)
  return `${browse}/mkdir`
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

export function folderParentBrowsePath(path: string): string {
  const trimmed = path.replace(/\/+$/, '')
  if (!trimmed || trimmed === '/') return ''
  const slash = trimmed.lastIndexOf('/')
  if (slash <= 0) return ''
  return trimmed.slice(0, slash)
}

export function withFolderParentEntry(entries: FolderEntry[], currentPath: string): FolderEntry[] {
  if (!currentPath) return entries
  if (entries.some((row) => row.name === '..')) return entries
  return [{ name: '..', path: folderParentBrowsePath(currentPath), isDirectory: true }, ...entries]
}
