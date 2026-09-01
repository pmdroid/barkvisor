export type ISOLibraryImage = {
  id: string
  imageType: string
  status: string
}

export type ISOAttachment = {
  isoId?: string | null
  isoIds?: string[] | null
}

export function attachedISOIds(vm: ISOAttachment | null | undefined): string[] {
  if (!vm) return []
  if (vm.isoIds && vm.isoIds.length > 0) return vm.isoIds
  if (vm.isoId) return [vm.isoId]
  return []
}

export function attachableISOImages<T extends ISOLibraryImage>(
  library: T[],
  attachedIds: string[],
): T[] {
  const attached = new Set(attachedIds)
  return library.filter(
    (image) => image.imageType === 'iso' && image.status === 'ready' && !attached.has(image.id),
  )
}
