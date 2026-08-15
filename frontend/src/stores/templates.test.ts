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
    const [path, body] = post.mock.calls[0] as [string, { memoryMB?: number; targetHostId?: string }]
    expect(path).toBe('/templates/tpl-1/deploy/dry-run')
    expect(body.memoryMB).toBe(128)
    expect(body.targetHostId).toBeUndefined()
  })

  test('routes member deploy/dry-run through the Home proxy and strips targetHostId', async () => {
    const post = mock((url: string) => {
      if (url.includes('dry-run')) {
        return Promise.resolve({
          data: {
            compatible: true,
            hostId: 'peer-1',
            hostArch: 'arm64',
            resolvedImageSlug: 'ubuntu',
            resolvedArch: 'arm64',
            reasons: [],
            missingFeatures: [],
            minMemoryMB: null,
          },
        })
      }
      return Promise.resolve({
        data: { status: 'created', imageId: null, vm: { id: 'vm-1' } },
      })
    })
    api.post = post as typeof api.post
    const store = useTemplateStore()
    const member = { hostId: 'peer-1', role: 'member', reachability: 'ok' }
    await store.dryRun('tpl-1', { memoryMB: 1024 }, member)
    await store.deploy(
      { templateId: 'tpl-1', vmName: 'box', inputs: {}, targetHostId: 'foreign' } as never,
      member,
    )
    const paths = post.mock.calls.map((c) => c[0])
    expect(paths).toEqual([
      '/home/devices/peer-1/v1/templates/tpl-1/deploy/dry-run',
      '/home/devices/peer-1/v1/templates/deploy',
    ])
    const deployBody = post.mock.calls[1]?.[1] as { targetHostId?: string }
    expect(deployBody.targetHostId).toBeUndefined()
  })
})
