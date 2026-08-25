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

/** Locations that already have the model. Start can only run on these Devices. */
export function ollamaStartLocations<T extends { hostId: string }>(
  model?: { locations: T[] } | null,
): T[] {
  return model?.locations ?? []
}

/** hostId when exactly one Device has the model. */
export function ollamaSoleStartHostId(model?: {
  locations: { hostId: string }[]
} | null): string | undefined {
  const locations = ollamaStartLocations(model)
  return locations.length === 1 ? locations[0].hostId : undefined
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
