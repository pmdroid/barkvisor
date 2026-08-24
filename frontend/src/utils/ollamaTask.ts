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

/** Task progress is 0...1 from the backend. */
export function ollamaPullPercent(progress: number | null | undefined): number | undefined {
  if (progress == null || Number.isNaN(progress)) return undefined
  return Math.round(Math.min(1, Math.max(0, progress)) * 100)
}
