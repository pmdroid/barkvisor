/** Home task GET/DELETE path for an Ollama pull (PAS-269). */
export function ollamaPullTaskPath(
  task: { taskID: string; hostId: string },
  selfHostId?: string | null,
): string {
  const id = encodeURIComponent(task.taskID)
  if (selfHostId && task.hostId === selfHostId) return `/tasks/${id}`
  return `/home/devices/${encodeURIComponent(task.hostId)}/v1/tasks/${id}`
}

/** Start payload without hostId so Home picks already-running, then healthier Device. */
export function ollamaStartBody(name: string): { name: string } {
  return { name }
}

/** Task progress is 0...1 from the backend. */
export function ollamaPullPercent(progress: number | null | undefined): number | undefined {
  if (progress == null || Number.isNaN(progress)) return undefined
  return Math.round(Math.min(1, Math.max(0, progress)) * 100)
}
