import type { ImageRepository } from '../api/types'
import { deviceDisplayLabel } from './deviceCompatibility'
import { reachabilityHint, reachabilityLabel } from './homeDeviceHealth'

export type CatalogDeviceRef = {
  hostId: string
  role?: string | null
  displayName?: string | null
  reachability?: string | null
  reachabilityError?: string | null
}

export type CatalogDeviceSync = {
  hostId: string
  label: string
  role: string | null
  reachable: boolean
  repoId: string | null
  syncStatus: string
  lastError: string | null
  lastSyncedAt: string | null
}

export type HomeCatalogRepository = ImageRepository & {
  deviceSyncs: CatalogDeviceSync[]
}

export type CatalogMemberFetch = {
  device: CatalogDeviceRef
  reachable: boolean
  repos?: ImageRepository[]
  error?: string
}

const githubImagesURL =
  'https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/images.json'
const githubTemplatesURL =
  'https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/templates.json'
const memberImagesURL = 'barkvisor://home/catalog/images'
const memberTemplatesURL = 'barkvisor://home/catalog/templates'

const catalogUrlAliases: Record<string, string> = {
  [githubImagesURL]: memberImagesURL,
  [memberImagesURL]: memberImagesURL,
  [githubTemplatesURL]: memberTemplatesURL,
  [memberTemplatesURL]: memberTemplatesURL,
}

export function catalogUrlKey(url: string): string {
  const key = url.trim()
  return catalogUrlAliases[key] ?? key
}

export function matchRepoByUrl(
  repos: ImageRepository[],
  url: string,
): ImageRepository | undefined {
  const key = catalogUrlKey(url)
  return repos.find((row) => catalogUrlKey(row.url) === key)
}

export function syncStatusLabel(
  status: string,
  lastError: string | null,
  lastSyncedAt: string | null,
): string {
  if (status === 'syncing') return 'syncing'
  if (status === 'error' || lastError) return 'error'
  if (lastSyncedAt) return 'synced'
  return 'idle'
}

export function syncStatusBadge(
  status: string,
  lastError: string | null,
  lastSyncedAt: string | null,
): string {
  if (status === 'syncing') return 'badge-amber'
  if (status === 'error' || lastError) return 'badge-red'
  if (lastSyncedAt) return 'badge-green'
  return 'badge-gray'
}

export function lastSyncedLabel(lastSyncedAt: string | null): string {
  if (!lastSyncedAt) return 'never'
  const parsed = new Date(lastSyncedAt)
  if (Number.isNaN(parsed.getTime())) return 'never'
  return parsed.toLocaleString()
}

export function catalogDeviceHasError(row: CatalogDeviceSync): boolean {
  return Boolean(row.lastError) || row.syncStatus === 'error' || !row.reachable
}

export function catalogHasDeviceError(
  repo: Pick<HomeCatalogRepository, 'deviceSyncs' | 'lastError' | 'syncStatus'>,
): boolean {
  if (repo.lastError || repo.syncStatus === 'error') return true
  return repo.deviceSyncs.some(catalogDeviceHasError)
}

export function catalogIsSyncing(
  repo: Pick<HomeCatalogRepository, 'deviceSyncs' | 'syncStatus'>,
): boolean {
  if (repo.syncStatus === 'syncing') return true
  return repo.deviceSyncs.some((row) => row.syncStatus === 'syncing')
}

export function deviceSyncFromRepo(
  device: CatalogDeviceRef,
  repo: ImageRepository,
): CatalogDeviceSync {
  return {
    hostId: device.hostId,
    label: deviceDisplayLabel(device),
    role: device.role ?? null,
    reachable: true,
    repoId: repo.id,
    syncStatus: repo.syncStatus,
    lastError: repo.lastError,
    lastSyncedAt: repo.lastSyncedAt,
  }
}

export function deviceSyncUnreachable(device: CatalogDeviceRef): CatalogDeviceSync {
  return {
    hostId: device.hostId,
    label: deviceDisplayLabel(device),
    role: device.role ?? null,
    reachable: false,
    repoId: null,
    syncStatus: 'error',
    lastError: reachabilityHint(device) || reachabilityLabel(device.reachability ?? undefined),
    lastSyncedAt: null,
  }
}

export function deviceSyncFetchFailed(
  device: CatalogDeviceRef,
  message: string,
): CatalogDeviceSync {
  return {
    hostId: device.hostId,
    label: deviceDisplayLabel(device),
    role: device.role ?? null,
    reachable: true,
    repoId: null,
    syncStatus: 'error',
    lastError: message,
    lastSyncedAt: null,
  }
}

export function deviceSyncMissingCatalog(device: CatalogDeviceRef): CatalogDeviceSync {
  return {
    hostId: device.hostId,
    label: deviceDisplayLabel(device),
    role: device.role ?? null,
    reachable: true,
    repoId: null,
    syncStatus: 'error',
    lastError: 'Catalog missing on this Device',
    lastSyncedAt: null,
  }
}

export function memberDeviceSync(
  result: CatalogMemberFetch,
  homeRepo: ImageRepository,
): CatalogDeviceSync | null {
  if (!result.reachable) return deviceSyncUnreachable(result.device)
  if (result.error) return deviceSyncFetchFailed(result.device, result.error)
  const match = matchRepoByUrl(result.repos ?? [], homeRepo.url)
  if (!match) {
    if (!homeRepo.isBuiltIn) return null
    return deviceSyncMissingCatalog(result.device)
  }
  return deviceSyncFromRepo(result.device, match)
}

export function attachDeviceSyncs(
  homeRepos: ImageRepository[],
  selfDevice: CatalogDeviceRef | null,
  memberResults: CatalogMemberFetch[],
): HomeCatalogRepository[] {
  return homeRepos.map((repo) => {
    const selfSync = selfDevice ? deviceSyncFromRepo(selfDevice, repo) : null
    const members = memberResults
      .map((result) => memberDeviceSync(result, repo))
      .filter((row): row is CatalogDeviceSync => row != null)
    const deviceSyncs = selfSync ? [selfSync, ...members] : members
    return { ...repo, deviceSyncs }
  })
}

export function asRepositories(data: unknown): ImageRepository[] {
  return Array.isArray(data) ? (data as ImageRepository[]) : []
}
