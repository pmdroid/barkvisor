export const DEVICE_SCOPE_ALL = 'all'
export const DEVICE_SCOPE_STORAGE_KEY = 'barkvisor.deviceScope'

export function parseDeviceScope(raw: string | null): 'all' | string {
  const value = raw?.trim() ?? ''
  if (!value || value.toLowerCase() === DEVICE_SCOPE_ALL) return DEVICE_SCOPE_ALL
  return value
}

export function isDeviceScopeAll(selectedHostId: string): boolean {
  return !selectedHostId || selectedHostId === DEVICE_SCOPE_ALL
}

export function scopeRows<T extends { hostId: string }>(
  rows: T[],
  selectedHostId: string,
): T[] {
  if (isDeviceScopeAll(selectedHostId)) return rows
  return rows.filter((row) => row.hostId === selectedHostId)
}

export function scopeOllamaModels<T extends { locations: { hostId: string }[] }>(
  models: T[],
  selectedHostId: string,
): T[] {
  if (isDeviceScopeAll(selectedHostId)) return models
  return models.filter((model) =>
    model.locations.some((loc) => loc.hostId === selectedHostId),
  )
}

export function scopeLibraryItems<T extends {
  copies?: { hostId: string }[]
  sourceHostIds?: string[]
}>(
  rows: T[],
  selectedHostId: string,
): T[] {
  if (isDeviceScopeAll(selectedHostId)) return rows
  return rows.filter((row) =>
    (row.copies ?? []).some((copy) => copy.hostId === selectedHostId)
    || (row.sourceHostIds ?? []).includes(selectedHostId),
  )
}
