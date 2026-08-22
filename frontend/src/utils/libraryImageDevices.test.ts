import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { HomeDeviceHealthSnapshot, Image } from '../api/types'
import type { HomeImage } from '../stores/homeLibrary'
import {
  libraryImageCopyOnDevice,
  readyLibraryImageDeviceChips,
} from './libraryImageDevices'

const here = dirname(fileURLToPath(import.meta.url))

function snapshot(
  partial: Partial<HomeDeviceHealthSnapshot> & Pick<HomeDeviceHealthSnapshot, 'hostId' | 'role'>,
): HomeDeviceHealthSnapshot {
  return {
    agentPort: 7778,
    reachability: 'ok',
    ...partial,
  }
}

function image(partial: Partial<HomeImage> & Pick<HomeImage, 'id' | 'name'>): HomeImage {
  const base: Image = {
    id: partial.id,
    name: partial.name,
    imageType: 'iso',
    arch: 'arm64',
    status: 'ready',
    sizeBytes: 1024,
    sourceUrl: null,
    error: null,
    sha256: 'abc',
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
  }
  return {
    ...base,
    ...partial,
    libraryKey: partial.libraryKey ?? `sha256:${base.sha256}`,
    sourceHostIds: partial.sourceHostIds ?? [],
    copies: partial.copies ?? [],
  }
}

describe('libraryImageDevices (PAS-221)', () => {
  test('chips use ready sourceHostIds only', () => {
    const self = snapshot({ hostId: 'desk', role: 'self', displayName: 'Desk' })
    const peer = snapshot({ hostId: 'studio', role: 'member', displayName: 'Studio' })
    const row = image({
      id: 'local-iso',
      name: 'ubuntu.iso',
      sourceHostIds: ['desk', 'studio'],
      copies: [
        { hostId: 'desk', imageId: 'local-iso', status: 'ready' },
        { hostId: 'studio', imageId: 'peer-iso', status: 'ready' },
        { hostId: 'garage', imageId: 'up', status: 'uploading' },
      ],
    })
    const chips = readyLibraryImageDeviceChips(row, [self, peer], (id) => id)
    expect(chips.map((c) => c.hostId)).toEqual(['desk', 'studio'])
    expect(chips[0]).toEqual({
      hostId: 'desk',
      label: 'Desk',
      self: true,
      reachable: true,
    })
    expect(chips[1]).toEqual({
      hostId: 'studio',
      label: 'Studio',
      self: false,
      reachable: true,
    })
  })

  test('uploading copy is omitted even if it leaked into sourceHostIds', () => {
    const row = image({
      id: 'local-iso',
      name: 'ubuntu.iso',
      sourceHostIds: ['desk', 'studio'],
      copies: [
        { hostId: 'desk', imageId: 'local-iso', status: 'ready' },
        { hostId: 'studio', imageId: 'peer-up', status: 'uploading' },
      ],
    })
    expect(readyLibraryImageDeviceChips(row, [], (id) => id).map((c) => c.hostId)).toEqual(['desk'])
  })

  test('unreachable member is still a chip with reachable false', () => {
    const peer = snapshot({
      hostId: 'studio',
      role: 'member',
      displayName: 'Studio',
      reachability: 'unreachable',
    })
    const row = image({
      id: 'peer-iso',
      name: 'ubuntu.iso',
      sourceHostIds: ['studio'],
      copies: [{ hostId: 'studio', imageId: 'peer-iso', status: 'ready' }],
    })
    expect(readyLibraryImageDeviceChips(row, [peer], (id) => id)).toEqual([{
      hostId: 'studio',
      label: 'Studio',
      self: false,
      reachable: false,
    }])
  })

  test('placeholder self copy maps to This Device and local delete id', () => {
    const row = image({
      id: 'local-iso',
      name: 'ubuntu.iso',
      sourceHostIds: ['self'],
      copies: [{ hostId: 'self', imageId: 'local-iso', status: 'ready' }],
    })
    const chips = readyLibraryImageDeviceChips(row, [], (id) => id)
    expect(chips).toEqual([{
      hostId: 'self',
      label: 'self',
      self: true,
      reachable: true,
    }])
    expect(libraryImageCopyOnDevice(row, 'desk', 'desk')?.imageId).toBe('local-iso')
    expect(libraryImageCopyOnDevice(row, 'self')?.imageId).toBe('local-iso')
    expect(libraryImageCopyOnDevice(row, 'studio', 'desk')).toBeUndefined()
  })

  test('Images page lists Home Library rows with Device chips', () => {
    const page = readFileSync(join(here, '../views/ImageLibraryView.vue'), 'utf8')
    expect(page).toContain('WorkloadDeviceChip')
    expect(page).toContain('readyLibraryImageDeviceChips')
    expect(page).toContain('homeLibrary.fetchImages')
    expect(page).toContain("{ key: 'device', label: 'Device' }")
    expect(page).not.toContain('cluster')
    expect(page).not.toContain('datacenter')
    expect(page).not.toContain('quorum')
    expect(page).not.toMatch(/\bnode\b/)
    expect(page).not.toMatch(/\bnodes\b/)
  })
})
