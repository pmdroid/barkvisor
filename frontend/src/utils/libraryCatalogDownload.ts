import type { RepositoryImage } from '../api/types'
import { devicePath, type DeviceApiTarget } from './homeDeviceApi'
import { normalizeImageArch } from './imageArch'

type RepoRow = { id: string; repoType?: string }

/**
 * Find a catalog image on another Device. Repo catalogs are fetched in
 * parallel; a failed GET is skipped so one stale repo cannot abort the scan.
 */
export async function findCatalogImageOnDevice(
  api: { get: (path: string) => Promise<{ data: unknown }> },
  device: DeviceApiTarget & { displayName?: string | null },
  img: Pick<RepositoryImage, 'slug' | 'arch' | 'name'>,
): Promise<RepositoryImage> {
  const { data: repos } = await api.get(devicePath(device, '/repositories'))
  const imageRepos = Array.isArray(repos)
    ? (repos as RepoRow[]).filter((row) => row.repoType === 'images')
    : []
  const wantArch = normalizeImageArch(img.arch)
  const results = await Promise.allSettled(
    imageRepos.map(async (repo) => {
      const { data: catalog } = await api.get(devicePath(device, `/repositories/${repo.id}/images`))
      if (!Array.isArray(catalog)) return null
      return (catalog as RepositoryImage[]).find((row) =>
        row.slug === img.slug && normalizeImageArch(row.arch) === wantArch,
      ) ?? null
    }),
  )
  for (const result of results) {
    if (result.status === 'fulfilled' && result.value) return result.value
  }
  const label = device.displayName?.trim() || device.hostId
  throw new Error(
    `“${img.name}” is not in ${label}'s catalog. Sync repositories on that Device.`,
  )
}
