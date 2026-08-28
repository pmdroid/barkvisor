import { afterEach, describe, expect, test } from 'bun:test'
import {
  BUILTIN_CATALOG_SYNC_THROTTLE_MS,
  nudgeBuiltInCatalogSync,
  resetBuiltInCatalogSyncThrottle,
} from './catalogSyncOnOpen'

describe('nudgeBuiltInCatalogSync', () => {
  afterEach(() => {
    resetBuiltInCatalogSyncThrottle()
  })

  test('posts built-in repos once then throttles', async () => {
    const posted: string[] = []
    const list = async () => [
      { id: 'images', isBuiltIn: true },
      { id: 'templates', isBuiltIn: true },
      { id: 'custom', isBuiltIn: false },
    ]
    const sync = async (id: string) => {
      posted.push(id)
    }
    const first = await nudgeBuiltInCatalogSync({ now: 1_000, list, sync })
    expect(first).toBe(2)
    expect(posted).toEqual(['images', 'templates'])
    const second = await nudgeBuiltInCatalogSync({
      now: 1_000 + BUILTIN_CATALOG_SYNC_THROTTLE_MS - 1,
      list,
      sync,
    })
    expect(second).toBe(0)
    expect(posted).toEqual(['images', 'templates'])
    const third = await nudgeBuiltInCatalogSync({
      now: 1_000 + BUILTIN_CATALOG_SYNC_THROTTLE_MS,
      list,
      sync,
    })
    expect(third).toBe(2)
  })
})
