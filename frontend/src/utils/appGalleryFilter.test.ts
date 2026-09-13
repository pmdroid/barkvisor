import { describe, expect, test } from 'bun:test'
import type { AppCatalogEntry } from '../api/types'
import {
  APP_GALLERY_ALL_CATEGORY,
  APP_GALLERY_FALLBACK_CATEGORY,
  appGalleryCategories,
  appGalleryCategory,
  appGalleryFilterSummary,
  appGalleryMatchesQuery,
  filterAppGallery,
} from './appGalleryFilter'

function app(partial: Partial<AppCatalogEntry> = {}): AppCatalogEntry {
  return {
    id: 'whoami',
    name: 'Whoami',
    category: 'Apps',
    arches: ['arm64', 'amd64'],
    source: 'big-bear-universal',
    compose: 'services:\n  whoami:\n    image: traefik/whoami\n',
    envSchema: [],
    volumes: [],
    ports: [],
    unsupportedReasons: [],
    ui: { scheme: 'http', path: '', proxy: 'direct', basePathEnv: [] },
    ...partial,
  }
}

const apps: AppCatalogEntry[] = [
  app({ id: 'jellyfin', name: 'Jellyfin', tagline: 'Media server for movies, TV and music', category: 'Media' }),
  app({ id: 'immich', name: 'Immich', tagline: 'Self-hosted photo and video backup', category: 'Media' }),
  app({ id: 'radarr', name: 'Radarr', tagline: 'Movie collection manager', category: 'Arr' }),
  app({ id: 'vaultwarden', name: 'Vaultwarden', tagline: 'Password manager', description: 'Bitwarden-compatible secrets store', category: 'Productivity' }),
  app({ id: 'code-server', name: 'Code Server', tagline: 'Browser IDE', category: '' }),
]

describe('appGalleryFilter', () => {
  test('falls back to Apps for missing or blank category', () => {
    expect(appGalleryCategory(app({ category: '' }))).toBe(APP_GALLERY_FALLBACK_CATEGORY)
    expect(appGalleryCategory(app({ category: '   ' }))).toBe(APP_GALLERY_FALLBACK_CATEGORY)
    expect(appGalleryCategory(app({ category: undefined }))).toBe(APP_GALLERY_FALLBACK_CATEGORY)
    expect(appGalleryCategory(app({ category: ' Media ' }))).toBe('Media')
  })

  test('categories list starts with All and counts every row', () => {
    const rows = appGalleryCategories(apps)
    expect(rows[0]).toEqual({ name: APP_GALLERY_ALL_CATEGORY, count: 5 })
    expect(rows.map((row) => row.name)).toEqual([
      APP_GALLERY_ALL_CATEGORY, 'Apps', 'Arr', 'Media', 'Productivity',
    ])
    expect(rows.find((row) => row.name === 'Media')?.count).toBe(2)
    expect(rows.find((row) => row.name === 'Arr')?.count).toBe(1)
    expect(rows.find((row) => row.name === APP_GALLERY_FALLBACK_CATEGORY)?.count).toBe(1)
  })

  test('query matches name case-insensitively', () => {
    const hits = filterAppGallery(apps, { query: 'JELLY', category: APP_GALLERY_ALL_CATEGORY })
    expect(hits.map((row) => row.id)).toEqual(['jellyfin'])
  })

  test('query matches tagline and description', () => {
    expect(filterAppGallery(apps, { query: 'photo', category: APP_GALLERY_ALL_CATEGORY }).map((r) => r.id)).toEqual(['immich'])
    expect(filterAppGallery(apps, { query: 'secrets store', category: APP_GALLERY_ALL_CATEGORY }).map((r) => r.id)).toEqual(['vaultwarden'])
  })

  test('multi-word query ANDs all terms', () => {
    expect(filterAppGallery(apps, { query: 'movie manager', category: APP_GALLERY_ALL_CATEGORY }).map((r) => r.id)).toEqual(['radarr'])
    expect(filterAppGallery(apps, { query: 'movie vaultwarden', category: APP_GALLERY_ALL_CATEGORY })).toEqual([])
  })

  test('empty and whitespace query matches everything', () => {
    expect(filterAppGallery(apps, { query: '   ', category: APP_GALLERY_ALL_CATEGORY }).length).toBe(apps.length)
    expect(appGalleryMatchesQuery(app(), '')).toBe(true)
  })

  test('category chip filters single-select', () => {
    expect(filterAppGallery(apps, { query: '', category: 'Media' }).map((r) => r.id)).toEqual(['jellyfin', 'immich'])
    expect(filterAppGallery(apps, { query: '', category: APP_GALLERY_FALLBACK_CATEGORY }).map((r) => r.id)).toEqual(['code-server'])
  })

  test('category and query combine with AND', () => {
    expect(filterAppGallery(apps, { query: 'movie', category: 'Media' }).map((r) => r.id)).toEqual(['jellyfin'])
    expect(filterAppGallery(apps, { query: 'movie', category: 'Arr' }).map((r) => r.id)).toEqual(['radarr'])
    expect(filterAppGallery(apps, { query: 'photo', category: 'Arr' })).toEqual([])
  })

  test('unsupported cards stay visible and searchable', () => {
    const blocked = app({ id: 'wireguard', name: 'WireGuard Easy', tagline: 'VPN management', unsupportedReasons: ['needs NET_ADMIN'], category: 'Networking' })
    const list = [...apps, blocked]
    const hits = filterAppGallery(list, { query: 'wireguard', category: 'Networking' })
    expect(hits.map((row) => row.id)).toEqual(['wireguard'])
    expect(hits[0].unsupportedReasons).toEqual(['needs NET_ADMIN'])
  })

  test('filter summary describes active filters', () => {
    expect(appGalleryFilterSummary({ query: '', category: APP_GALLERY_ALL_CATEGORY })).toBe('no filters')
    expect(appGalleryFilterSummary({ query: '', category: 'Media' })).toBe('filtered · Media')
    expect(appGalleryFilterSummary({ query: '  photo ', category: APP_GALLERY_ALL_CATEGORY })).toBe('filtered · "photo"')
    expect(appGalleryFilterSummary({ query: 'photo', category: 'Media' })).toBe('filtered · Media + "photo"')
  })
})
