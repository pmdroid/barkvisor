import { formatBytes } from './format'

const librarySettingsListeners = new Set<() => void>()

/** Notify Images (and other listeners) after a Library path save. */
export function bumpLibrarySettingsEpoch() {
  for (const listener of librarySettingsListeners) listener()
}

export function onLibrarySettingsChanged(listener: () => void): () => void {
  librarySettingsListeners.add(listener)
  return () => {
    librarySettingsListeners.delete(listener)
  }
}

/**
 * Humanized Library volume: "X GB free of Y GB".
 * Null when capacity is unknown (missing key or JSON null) — never "0 GB free of 0 GB".
 */
export function librarySpaceCopy(
  totalBytes: number | null | undefined,
  freeBytes: number | null | undefined,
): string | null {
  if (
    totalBytes == null ||
    freeBytes == null ||
    !Number.isFinite(totalBytes) ||
    !Number.isFinite(freeBytes) ||
    totalBytes <= 0 ||
    freeBytes < 0 ||
    freeBytes > totalBytes
  ) {
    return null
  }
  const freeLabel = freeBytes === 0 ? '0 B' : formatBytes(freeBytes)
  return `${freeLabel} free of ${formatBytes(totalBytes)}`
}
