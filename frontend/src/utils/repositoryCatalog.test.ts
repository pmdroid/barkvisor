import { describe, expect, test } from 'bun:test'
import type { ImageRepository } from '../api/types'
import {
  attachDeviceSyncs,
  catalogHasDeviceError,
  catalogIsSyncing,
  catalogUrlKey,
  lastSyncedLabel,
  matchRepoByUrl,
  memberDeviceSync,
  syncStatusBadge,
  syncStatusLabel,
} from './repositoryCatalog'

function repo(
  partial: Partial<ImageRepository> & Pick<ImageRepository, 'id' | 'url'>,
): ImageRepository {
  return {
    name: 'Catalog',
    isBuiltIn: true,
    repoType: 'templates',
    lastSyncedAt: null,
    lastError: null,
    syncStatus: 'idle',
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    ...partial,
  }
}

describe('repositoryCatalog helpers', () => {
  test('syncStatusLabel and badge follow lastError then lastSyncedAt', () => {
    expect(syncStatusLabel('syncing', null, null)).toBe('syncing')
    expect(syncStatusBadge('syncing', null, null)).toBe('badge-amber')
    expect(syncStatusLabel('idle', 'decode failed', null)).toBe('error')
    expect(syncStatusBadge('idle', 'decode failed', null)).toBe('badge-red')
    expect(syncStatusLabel('error', null, null)).toBe('error')
    expect(syncStatusLabel('idle', null, '2026-01-02T00:00:00Z')).toBe('synced')
    expect(syncStatusBadge('idle', null, '2026-01-02T00:00:00Z')).toBe('badge-green')
    expect(syncStatusLabel('idle', null, null)).toBe('idle')
    expect(syncStatusBadge('idle', null, null)).toBe('badge-gray')
  })

  test('lastSyncedLabel formats ISO or never', () => {
    expect(lastSyncedLabel(null)).toBe('never')
    expect(lastSyncedLabel('')).toBe('never')
    expect(lastSyncedLabel('not-a-date')).toBe('never')
    expect(lastSyncedLabel('2026-08-28T16:00:00.000Z')).toBe(
      new Date('2026-08-28T16:00:00.000Z').toLocaleString(),
    )
  })

  test('matchRepoByUrl uses trimmed URL, not Device-local ids', () => {
    const rows = [
      repo({ id: 'peer-a', url: ' https://example.com/catalog.json ' }),
      repo({ id: 'peer-b', url: 'https://other.example/catalog.json' }),
    ]
    expect(catalogUrlKey(' https://example.com/catalog.json')).toBe(
      'https://example.com/catalog.json',
    )
    expect(matchRepoByUrl(rows, 'https://example.com/catalog.json')?.id).toBe('peer-a')
    expect(matchRepoByUrl(rows, 'https://missing.example/catalog.json')).toBeUndefined()
  })

  test('GitHub built-in URLs alias Home-origin member catalogs', () => {
    const githubImages =
      'https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/images.json'
    const githubTemplates =
      'https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/templates.json'
    const memberImages = 'barkvisor://home/catalog/images'
    const memberTemplates = 'barkvisor://home/catalog/templates'
    const rows = [
      repo({ id: 'img', url: memberImages, repoType: 'images' }),
      repo({ id: 'tpl', url: memberTemplates, repoType: 'templates' }),
    ]
    expect(matchRepoByUrl(rows, githubImages)?.id).toBe('img')
    expect(matchRepoByUrl(rows, githubTemplates)?.id).toBe('tpl')
    expect(matchRepoByUrl(rows, githubImages)?.id).not.toBe('tpl')
    expect(catalogUrlKey(githubImages)).toBe(catalogUrlKey(memberImages))
    expect(catalogUrlKey(githubTemplates)).toBe(catalogUrlKey(memberTemplates))
    expect(catalogUrlKey(githubImages)).not.toBe(catalogUrlKey(githubTemplates))
  })

  test('member Home-origin catalogs keep real sync status for built-in GitHub rows', () => {
    const githubImages =
      'https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/images.json'
    const githubTemplates =
      'https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/templates.json'
    const homeImages = repo({
      id: 'home-images',
      url: githubImages,
      repoType: 'images',
      lastSyncedAt: '2026-08-28T10:00:00Z',
    })
    const homeTemplates = repo({
      id: 'home-templates',
      url: githubTemplates,
      repoType: 'templates',
      lastSyncedAt: '2026-08-28T10:00:00Z',
    })
    const member = {
      device: {
        hostId: '3E91D9E1-79F7-42F5-AFB7-BBBFC518656A',
        role: 'member',
        displayName: 'agentbox',
      },
      reachable: true,
      repos: [
        repo({
          id: 'agentbox-images',
          url: 'barkvisor://home/catalog/images',
          repoType: 'images',
          syncStatus: 'idle',
          lastSyncedAt: '2026-08-27T18:00:00Z',
        }),
        repo({
          id: 'agentbox-templates',
          url: 'barkvisor://home/catalog/templates',
          repoType: 'templates',
          syncStatus: 'error',
          lastError: null,
        }),
      ],
    }
    const attached = attachDeviceSyncs(
      [homeImages, homeTemplates],
      { hostId: 'desk', role: 'self', displayName: 'Desk' },
      [member],
    )
    const imagesMember = attached[0]?.deviceSyncs.find(
      (d) => d.hostId === member.device.hostId,
    )
    const templatesMember = attached[1]?.deviceSyncs.find(
      (d) => d.hostId === member.device.hostId,
    )
    expect(imagesMember?.repoId).toBe('agentbox-images')
    expect(imagesMember?.syncStatus).toBe('idle')
    expect(imagesMember?.lastSyncedAt).toBe('2026-08-27T18:00:00Z')
    expect(imagesMember?.lastError).toBeNull()
    expect(templatesMember?.repoId).toBe('agentbox-templates')
    expect(templatesMember?.syncStatus).toBe('error')
    expect(templatesMember?.lastError).toBeNull()
    expect(attached.flatMap((row) => row.deviceSyncs.map((d) => d.lastError))).not.toContain(
      'Catalog missing on this Device',
    )
  })

  test('built-in member lastError stays visible without Create VM', () => {
    const home = repo({
      id: 'home-1',
      url: 'https://example.com/catalog.json',
      lastSyncedAt: '2026-01-02T00:00:00Z',
    })
    const attached = attachDeviceSyncs(
      [home],
      { hostId: 'desk', role: 'self', displayName: 'Desk' },
      [
        {
          device: { hostId: 'studio', role: 'member', displayName: 'Studio' },
          reachable: true,
          repos: [
            repo({
              id: 'studio-1',
              url: 'https://example.com/catalog.json',
              syncStatus: 'error',
              lastError: 'data isn\'t in the correct format',
            }),
          ],
        },
        {
          device: { hostId: 'garage', role: 'member', displayName: 'Garage', reachability: 'unreachable' },
          reachable: false,
        },
      ],
    )
    expect(attached).toHaveLength(1)
    const row = attached[0]!
    expect(row.deviceSyncs.map((d) => d.hostId)).toEqual(['desk', 'studio', 'garage'])
    expect(row.deviceSyncs[1]?.lastError).toBe("data isn't in the correct format")
    expect(row.deviceSyncs[1]?.repoId).toBe('studio-1')
    expect(row.deviceSyncs[2]?.reachable).toBe(false)
    expect(row.deviceSyncs[2]?.lastError).toBeTruthy()
    expect(catalogHasDeviceError(row)).toBe(true)
    expect(catalogIsSyncing(row)).toBe(false)
  })

  test('member hop failure is an error on that Device', () => {
    const home = repo({ id: 'home-1', url: 'https://example.com/catalog.json' })
    const sync = memberDeviceSync(
      {
        device: { hostId: 'studio', role: 'member', displayName: 'Studio' },
        reachable: true,
        error: 'Device did not answer',
      },
      home,
    )
    expect(sync?.lastError).toBe('Device did not answer')
    expect(sync?.syncStatus).toBe('error')
    expect(sync?.repoId).toBeNull()
  })

  test('custom catalogs skip members that do not have the URL', () => {
    const custom = repo({
      id: 'custom-1',
      url: 'https://mine.example/catalog.json',
      isBuiltIn: false,
    })
    const attached = attachDeviceSyncs(
      [custom],
      { hostId: 'desk', role: 'self', displayName: 'Desk' },
      [
        {
          device: { hostId: 'studio', role: 'member', displayName: 'Studio' },
          reachable: true,
          repos: [repo({ id: 'studio-1', url: 'https://example.com/catalog.json' })],
        },
      ],
    )
    expect(attached[0]?.deviceSyncs.map((d) => d.hostId)).toEqual(['desk'])
  })

  test('catalogIsSyncing is true when any Device is syncing', () => {
    const home = repo({ id: 'home-1', url: 'https://example.com/catalog.json' })
    const attached = attachDeviceSyncs(
      [home],
      { hostId: 'desk', role: 'self', displayName: 'Desk' },
      [
        {
          device: { hostId: 'studio', role: 'member', displayName: 'Studio' },
          reachable: true,
          repos: [
            repo({
              id: 'studio-1',
              url: 'https://example.com/catalog.json',
              syncStatus: 'syncing',
            }),
          ],
        },
      ],
    )
    expect(catalogIsSyncing(attached[0]!)).toBe(true)
  })
})
