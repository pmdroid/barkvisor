/**
 * Client-side search + category filtering for the Apps gallery
 * (Create App drawer and the Library Apps tab).
 * See docs/app-workloads-mockups/apps-search-plan.md.
 */

/** Fields the gallery filter reads; HomeApp/AppCatalogEntry both satisfy this. */
export interface AppGalleryFilterable {
  name: string
  tagline?: string | null
  description?: string | null
  category?: string | null
}

export interface AppGalleryFilterState {
  query: string
  category: string
}

export interface AppGalleryCategoryRow {
  name: string
  count: number
}

export const APP_GALLERY_ALL_CATEGORY = 'All'
export const APP_GALLERY_FALLBACK_CATEGORY = 'Apps'

/** Catalog `category` may be empty (LinuxServer entries); fall back to "Apps". */
export function appGalleryCategory(app: AppGalleryFilterable): string {
  const trimmed = app.category?.trim() ?? ''
  return trimmed || APP_GALLERY_FALLBACK_CATEGORY
}

/** "All" (total) first, then every category present in the list, alphabetical. */
export function appGalleryCategories(apps: AppGalleryFilterable[]): AppGalleryCategoryRow[] {
  const counts = new Map<string, number>()
  for (const app of apps) {
    const category = appGalleryCategory(app)
    counts.set(category, (counts.get(category) ?? 0) + 1)
  }
  const rows: AppGalleryCategoryRow[] = [{ name: APP_GALLERY_ALL_CATEGORY, count: apps.length }]
  for (const name of [...counts.keys()].sort((a, b) => a.localeCompare(b))) {
    rows.push({ name, count: counts.get(name) ?? 0 })
  }
  return rows
}

function appSearchHaystack(app: AppGalleryFilterable): string {
  return [app.name, app.tagline ?? '', app.description ?? '']
    .join(' ')
    .toLowerCase()
}

/** Every whitespace-separated term must appear in name, tagline or description. */
export function appGalleryMatchesQuery(app: AppGalleryFilterable, query: string): boolean {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean)
  if (terms.length === 0) return true
  const haystack = appSearchHaystack(app)
  return terms.every((term) => haystack.includes(term))
}

export function appGalleryMatches(app: AppGalleryFilterable, state: AppGalleryFilterState): boolean {
  if (state.category !== APP_GALLERY_ALL_CATEGORY && appGalleryCategory(app) !== state.category) {
    return false
  }
  return appGalleryMatchesQuery(app, state.query)
}

/** Search AND category. Disabled/unsupported cards stay in the list so search can still find them. */
export function filterAppGallery<T extends AppGalleryFilterable>(
  apps: T[],
  state: AppGalleryFilterState,
): T[] {
  return apps.filter((app) => appGalleryMatches(app, state))
}

/** Human-readable description of the active filters, e.g. `filtered · Media + "photo"`. */
export function appGalleryFilterSummary(state: AppGalleryFilterState): string {
  const parts: string[] = []
  if (state.category !== APP_GALLERY_ALL_CATEGORY) parts.push(state.category)
  const query = state.query.trim()
  if (query) parts.push(`"${query}"`)
  return parts.length ? `filtered · ${parts.join(' + ')}` : 'no filters'
}
