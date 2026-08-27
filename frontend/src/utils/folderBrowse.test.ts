import { describe, expect, test } from 'bun:test'
import {
  asFolderEntries,
  folderBrowseParams,
  folderBrowseRequestPath,
  folderHasRealEntries,
} from './folderBrowse'

const self = { hostId: 'desk-1', role: 'self' }
const member = { hostId: 'peer/1', role: 'member' }

describe('folderBrowse', () => {
  test('browse path is local for this Device and proxied for members', () => {
    expect(folderBrowseRequestPath()).toBe('/system/browse')
    expect(folderBrowseRequestPath(null)).toBe('/system/browse')
    expect(folderBrowseRequestPath(self)).toBe('/system/browse')
    expect(folderBrowseRequestPath(member)).toBe('/home/devices/peer%2F1/v1/system/browse')
    expect(folderBrowseRequestPath(undefined, 'setup')).toBe('/browse')
    expect(folderBrowseRequestPath(member, 'setup')).toBe('/browse')
  })

  test('empty path omits the query so the host lists roots', () => {
    expect(folderBrowseParams('')).toEqual({})
    expect(folderBrowseParams('/Users/pascal')).toEqual({ path: '/Users/pascal' })
  })

  test('asFolderEntries accepts a JSON array or an entries wrapper', () => {
    expect(asFolderEntries(null)).toEqual([])
    expect(asFolderEntries({})).toEqual([])
    expect(asFolderEntries([{ name: 'Documents', path: '/Users/pascal/Documents' }])).toEqual([
      { name: 'Documents', path: '/Users/pascal/Documents' },
    ])
    expect(
      asFolderEntries({
        entries: [
          { name: '..', path: '' },
          { name: 'disks', path: '/var/lib/barkvisor/disks' },
          { name: 1 },
        ],
      }),
    ).toEqual([
      { name: '..', path: '' },
      { name: 'disks', path: '/var/lib/barkvisor/disks' },
    ])
  })

  test('root listings count as real folders even with a parent row', () => {
    expect(folderHasRealEntries([])).toBe(false)
    expect(folderHasRealEntries([{ name: '..', path: '', isDirectory: true }])).toBe(false)
    expect(
      folderHasRealEntries([
        { name: '..', path: '', isDirectory: true },
        { name: 'pascal', path: '/Users/pascal', isDirectory: true },
      ]),
    ).toBe(true)
  })
})
