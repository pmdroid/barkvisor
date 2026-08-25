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
  for (const loc of locations) {
    if (loc.reachable) reachable.push(loc)
    else unreachable.push(loc)
  }
  return reachable.concat(unreachable)
}

/** hostId when exactly one reachable Device has the model, or the only location if it is down. */
export function ollamaSoleStartHostId(model?: {
  locations: { hostId: string; reachable?: boolean }[]
} | null): string | undefined {
  const locations = ollamaStartLocations(model)
  const reachable = locations.filter((loc) => loc.reachable)
  if (reachable.length === 1) return reachable[0].hostId
  if (locations.length === 1) return locations[0].hostId
  return undefined
}

/** First reachable Device that has the model. Unreachable is never the default. */
export function ollamaDefaultStartHostId(model?: {
  locations: { hostId: string; reachable?: boolean }[]
} | null): string | undefined {
  return ollamaStartLocations(model).find((loc) => loc.reachable)?.hostId
}

/** True when Start must pick among multiple Devices that have the model. */
export function ollamaStartNeedsPicker(model?: {
  locations: unknown[]
} | null): boolean {
  return (model?.locations.length ?? 0) > 1
}

/** Task progress is 0...1 from the backend. */
export function ollamaPullPercent(progress: number | null | undefined): number | undefined {
  if (progress == null || Number.isNaN(progress)) return undefined
  return Math.round(Math.min(1, Math.max(0, progress)) * 100)
}
