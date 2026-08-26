import { describe, expect, test } from 'bun:test'
import { diskAttachments, isDiskInUse } from './diskAttachment'

describe('diskAttachments', () => {
  test('returns attachedTo entries when present', () => {
    const disk = {
      vmId: null,
      attachedTo: [{ vmId: 'vm-1', vmName: 'web' }],
    }
    expect(diskAttachments(disk)).toEqual([{ vmId: 'vm-1', vmName: 'web' }])
    expect(isDiskInUse(disk)).toBe(true)
  })

  test('falls back to vmId when attachedTo is missing', () => {
    const disk = { vmId: 'vm-9' }
    expect(diskAttachments(disk)).toEqual([{ vmId: 'vm-9', vmName: 'vm-9' }])
    expect(isDiskInUse(disk)).toBe(true)
  })

  test('falls back to vmId when attachedTo is empty', () => {
    const disk = { vmId: 'vm-9', attachedTo: [] }
    expect(diskAttachments(disk)).toEqual([{ vmId: 'vm-9', vmName: 'vm-9' }])
    expect(isDiskInUse(disk)).toBe(true)
  })

  test('prefers attachedTo over vmId', () => {
    const disk = {
      vmId: 'vm-legacy',
      attachedTo: [{ vmId: 'vm-1', vmName: 'web' }],
    }
    expect(diskAttachments(disk)).toEqual([{ vmId: 'vm-1', vmName: 'web' }])
  })

  test('unattached disk has no attachments', () => {
    const disk = { vmId: null }
    expect(diskAttachments(disk)).toEqual([])
    expect(isDiskInUse(disk)).toBe(false)
  })
})
