import { describe, expect, test } from 'bun:test'
import { findCatalogImageOnDevice } from './libraryCatalogDownload'

describe('findCatalogImageOnDevice', () => {
  test('uses the first slug+arch hit and ignores a failed repo GET', async () => {
    const device = { hostId: 'peer', role: 'member', reachability: 'ok', displayName: 'peer' }
    const calls: string[] = []
    const api = {
      get: async (path: string) => {
        calls.push(path)
        if (path.endsWith('/repositories')) {
          return {
            data: [
              { id: 'broken', repoType: 'images' },
              { id: 'ok', repoType: 'images' },
              { id: 'templates', repoType: 'templates' },
            ],
          }
        }
        if (path.includes('/repositories/broken/images')) {
          throw new Error('catalog unavailable')
        }
        if (path.includes('/repositories/ok/images')) {
          return {
            data: [
              { id: 'img-1', slug: 'ubuntu', arch: 'x86_64', name: 'Ubuntu' },
            ],
          }
        }
        throw new Error(`unexpected ${path}`)
      },
    }

    const match = await findCatalogImageOnDevice(api, device, {
      slug: 'ubuntu',
      arch: 'x86_64',
      name: 'Ubuntu',
    })
    expect(match.id).toBe('img-1')
    expect(calls.some((path) => path.includes('/repositories/broken/images'))).toBe(true)
    expect(calls.some((path) => path.includes('/repositories/ok/images'))).toBe(true)
  })

  test('throws when no repo has the slug+arch', async () => {
    const device = { hostId: 'peer', role: 'member', reachability: 'ok', displayName: 'peer' }
    const api = {
      get: async (path: string) => {
        if (path.endsWith('/repositories')) {
          return { data: [{ id: 'ok', repoType: 'images' }] }
        }
        return { data: [{ id: 'img-1', slug: 'other', arch: 'arm64', name: 'Other' }] }
      },
    }
    await expect(
      findCatalogImageOnDevice(api, device, { slug: 'ubuntu', arch: 'x86_64', name: 'Ubuntu' }),
    ).rejects.toThrow(/not in peer's catalog/)
  })
})
