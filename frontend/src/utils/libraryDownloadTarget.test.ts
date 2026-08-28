import { describe, expect, test } from 'vitest'
import { catalogDownloadBlockedReason, deviceForCatalogImage } from './libraryDownloadTarget'

const agentbox = {
  hostId: 'x86',
  role: 'self',
  reachability: 'ok',
  displayName: 'agentbox',
  platform: { arch: 'x86_64' },
}

const ubuntu = {
  hostId: 'arm',
  role: 'member',
  reachability: 'ok',
  displayName: 'barkvisor-u24',
  platform: { arch: 'arm64' },
}

describe('deviceForCatalogImage', () => {
  test('prefers this Device when it can run the image', () => {
    expect(deviceForCatalogImage('x86_64', [agentbox, ubuntu])?.hostId).toBe('x86')
  })

  test('picks a reachable ARM64 member for arm64 catalog images', () => {
    expect(deviceForCatalogImage('aarch64', [agentbox, ubuntu])?.displayName).toBe('barkvisor-u24')
  })

  test('skips an unreachable member', () => {
    expect(
      deviceForCatalogImage('arm64', [agentbox, { ...ubuntu, reachability: 'offline' }]),
    ).toBeNull()
  })

  test('unknown image arch does not guess a Device', () => {
    expect(deviceForCatalogImage(null, [agentbox, ubuntu])).toBeNull()
  })
})

describe('catalogDownloadBlockedReason', () => {
  test('blocks when Device health has not loaded', () => {
    expect(catalogDownloadBlockedReason({ healthError: null, hasReport: false })).toBeTruthy()
  })

  test('blocks when the last health fetch failed', () => {
    expect(catalogDownloadBlockedReason({ healthError: 'Failed to fetch', hasReport: true })).toBeTruthy()
  })

  test('allows download when health is current', () => {
    expect(catalogDownloadBlockedReason({ healthError: null, hasReport: true })).toBeNull()
  })
})
