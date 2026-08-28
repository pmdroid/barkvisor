export const BUILTIN_CATALOG_SYNC_THROTTLE_MS = 10 * 60 * 1000

let lastFiredAt = 0

export function resetBuiltInCatalogSyncThrottle() {
  lastFiredAt = 0
}

export async function nudgeBuiltInCatalogSync(opts: {
  now?: number
  list: () => Promise<{ id: string; isBuiltIn: boolean }[]>
  sync: (id: string) => Promise<unknown>
}): Promise<number> {
  const now = opts.now ?? Date.now()
  if (lastFiredAt !== 0 && now - lastFiredAt < BUILTIN_CATALOG_SYNC_THROTTLE_MS) return 0
  lastFiredAt = now
  let posted = 0
  try {
    const repos = await opts.list()
    for (const repo of repos) {
      if (!repo.isBuiltIn) continue
      posted += 1
      void opts.sync(repo.id).catch(() => {})
    }
  } catch {
    return posted
  }
  return posted
}
