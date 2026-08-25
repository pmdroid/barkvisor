export function ollamaLibrarySearchQuery(raw: string): string | null {
  const q = raw.trim()
  return q ? q : null
}

export function ollamaLibraryResultName(result: { name?: string | null } | null | undefined): string {
  return result?.name?.trim() ?? ''
}
