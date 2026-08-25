/** Home task GET/DELETE path for an Ollama pull (PAS-269). */
export function ollamaPullTaskPath(
  task: { taskID: string; hostId: string },
  selfHostId?: string | null,
): string {
  const id = encodeURIComponent(task.taskID)
  if (selfHostId && task.hostId === selfHostId) return `/tasks/${id}`
  return `/home/devices/${encodeURIComponent(task.hostId)}/v1/tasks/${id}`
}

/** Start JSON is `{ name, hostId? }`. Omit hostId so Home picks already-running, then healthier Device. */
export function ollamaStartBody(
  name: string,
  hostId?: string,
): { name: string; hostId?: string } {
  return hostId ? { name, hostId } : { name }
}

/** Client-side Models table filter. Empty query matches every name. */
export function ollamaModelMatchesName(name: string, query: string): boolean {
  const q = query.trim().toLowerCase()
  if (!q) return true
  return name.toLowerCase().includes(q)
}

/** Running Device for Stop. Uses the live catalog row, not a dialog snapshot. */
export function ollamaRunningHostId(model?: {
  running: boolean
  locations: { hostId: string; running: boolean }[]
} | null): string | undefined {
  if (!model?.running) return undefined
  return model.locations.find((loc) => loc.running)?.hostId
}

/** Locations that already have the model. Reachable Devices first; unreachable stay listed. */
export function ollamaStartLocations<T extends { hostId: string; reachable?: boolean }>(
  model?: { locations: T[] } | null,
): T[] {
  const locations = model?.locations ?? []
  const reachable: T[] = []
  const unreachable: T[] = []
  const seen = new Set<string>()
  for (const loc of locations) {
    if (seen.has(loc.hostId)) continue
    seen.add(loc.hostId)
    if (loc.reachable) reachable.push(loc)
    else unreachable.push(loc)
  }
  return reachable.concat(unreachable)
}

/** Sidebar Device when it is one Device, not All. */
export function ollamaStartScopeHostId(selectedHostId?: string | null): string | undefined {
  const id = selectedHostId?.trim()
  if (!id || id.toLowerCase() === 'all') return undefined
  return id
}

/** Deduped locations, optionally intersected with the sidebar Device. */
export function ollamaStartCandidates<T extends { hostId: string; reachable?: boolean }>(
  model?: { locations: T[] } | null,
  selectedHostId?: string | null,
): T[] {
  const locations = ollamaStartLocations(model)
  const scoped = ollamaStartScopeHostId(selectedHostId)
  if (!scoped) return locations
  return locations.filter((loc) => loc.hostId === scoped)
}

export function ollamaStartReachableCandidates<T extends { hostId: string; reachable?: boolean }>(
  model?: { locations: T[] } | null,
  selectedHostId?: string | null,
): T[] {
  return ollamaStartCandidates(model, selectedHostId).filter((loc) => loc.reachable)
}

/** hostId when exactly one reachable Device has the model. */
export function ollamaSoleStartHostId(
  model?: { locations: { hostId: string; reachable?: boolean }[] } | null,
  selectedHostId?: string | null,
): string | undefined {
  const reachable = ollamaStartReachableCandidates(model, selectedHostId)
  if (reachable.length === 1) return reachable[0].hostId
  return undefined
}

/** First reachable Device that has the model. Unreachable is never the default. */
export function ollamaDefaultStartHostId(
  model?: { locations: { hostId: string; reachable?: boolean }[] } | null,
  selectedHostId?: string | null,
): string | undefined {
  return ollamaStartReachableCandidates(model, selectedHostId)[0]?.hostId
}

/** True when Start must pick among multiple reachable Devices that have the model. */
export function ollamaStartNeedsPicker(
  model?: { locations: { hostId: string; reachable?: boolean }[] } | null,
  selectedHostId?: string | null,
): boolean {
  return ollamaStartReachableCandidates(model, selectedHostId).length > 1
}

export function ollamaStartCanStart(
  model?: { locations: { hostId: string; reachable?: boolean }[] } | null,
  selectedHostId?: string | null,
): boolean {
  return ollamaStartReachableCandidates(model, selectedHostId).length >= 1
}

export function ollamaStartDisabledReason(
  model?: { locations: { hostId: string; reachable?: boolean }[] } | null,
  selectedHostId?: string | null,
): string | undefined {
  if (ollamaStartCanStart(model, selectedHostId)) return undefined
  if (ollamaStartScopeHostId(selectedHostId)) return 'Model is not on this Device'
  return 'Model is on Devices that are unreachable'
}

/** Task progress is 0...1 from the backend. */
export function ollamaPullPercent(progress: number | null | undefined): number | undefined {
  if (progress == null || Number.isNaN(progress)) return undefined
  return Math.round(Math.min(1, Math.max(0, progress)) * 100)
}
