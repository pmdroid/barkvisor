import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import { useTemplateStore } from './templates'

const originalPost = api.post

describe('template dry-run (PAS-33)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.post = originalPost
  })

  test('forwards memoryMB so dry-run matches deploy overrides', async () => {
    const post = mock(() =>
      Promise.resolve({
        data: {
          compatible: false,
          hostId: 'h1',
          hostArch: 'x86_64',
          resolvedImageSlug: 'ubuntu-24.04-x86_64',
          resolvedArch: 'x86_64',
          reasons: [{ code: 'min_memory', message: 'needs 512' }],
          missingFeatures: [],
          minMemoryMB: 512,
        },
      }),
    )
    api.post = post as typeof api.post

    const store = useTemplateStore()
    const report = await store.dryRun('tpl-1', { memoryMB: 128 })
    expect(report.compatible).toBe(false)
    expect(post).toHaveBeenCalledTimes(1)
    const [path, body] = post.mock.calls[0] as [string, { memoryMB?: number }]
    expect(path).toBe('/templates/tpl-1/deploy/dry-run')
    expect(body.memoryMB).toBe(128)
  })
})
