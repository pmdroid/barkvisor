import type { Disk, DiskAttachment } from '../api/types'

type DiskAttachmentSource = Pick<Disk, 'vmId'> & { attachedTo?: DiskAttachment[] }

export function diskAttachments(disk: DiskAttachmentSource): DiskAttachment[] {
  if (disk.attachedTo && disk.attachedTo.length > 0) return disk.attachedTo
  if (disk.vmId) return [{ vmId: disk.vmId, vmName: disk.vmId }]
  return []
}

export function isDiskInUse(disk: DiskAttachmentSource): boolean {
  return diskAttachments(disk).length > 0
}
