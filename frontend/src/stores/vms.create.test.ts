import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import { useVMStore } from './vms'

const originalPost = api.post

describe('vms.create (PAS-34)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.post = originalPost
  })

  test('self stays on /vms; members POST through the Home proxy', async () => {
    const post = mock((url: string) =>
      Promise.resolve({ status: 200, data: { id: 'vm-1', name: 'box', state: 'stopped' } }),
    )
    api.post = post as typeof api.post
    const store = useVMStore()
    await store.create({ name: 'local', osFamily: 'linux', cpuCount: 1, memoryMB: 512 } as never)
    await store.create(
      { name: 'remote', osFamily: 'linux', cpuCount: 1, memoryMB: 512, targetHostId: 'foreign' } as never,
      { hostId: 'peer-1', role: 'member', reachability: 'ok' },
    )
    expect(post.mock.calls.map((c) => c[0])).toEqual(['/vms', '/home/devices/peer-1/v1/vms'])
    const remoteBody = post.mock.calls[1]?.[1] as { targetHostId?: string }
    expect(remoteBody.targetHostId).toBeUndefined()
    expect(store.vms).toHaveLength(1)
    expect(store.vms[0]?.name).toBe('box')
  })
})
