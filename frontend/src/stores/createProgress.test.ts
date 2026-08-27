import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import { useCreateProgressStore } from './createProgress'
import { useDeviceWorkloadsStore } from './deviceWorkloads'
import { useToastStore } from './toast'

const originalGet = api.get
const originalPost = api.post

function provisionVm() {
  return {
    id: 'vm-alma',
    name: 'alma',
    state: 'provisioning',
    health: 'starting',
    vmType: 'linux-arm64',
    cpuCount: 2,
    memoryMB: 2048,
    bootDiskId: 'd1',
    isoId: null,
    isoIds: null,
    networkId: null,
    cloudInitPath: null,
    description: null,
    bootOrder: null,
    displayResolution: null,
    additionalDiskIds: null,
    uefi: true,
    tpmEnabled: false,
    macAddress: null,
    sharedPaths: null,
    portForwards: null,
    usbDevices: null,
    pendingChanges: false,
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
  }
}

describe('createProgress', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    useCreateProgressStore().intervalMs = 0
  })

  afterEach(() => {
    useCreateProgressStore().cancelAll()
    api.get = originalGet
    api.post = originalPost
  })

  test('downloading row then provision after image ready', async () => {
    let imageStatus = 'downloading'
    let imageGets = 0
    api.get = mock((url: string) => {
      if (String(url).includes('/images/img-1')) {
        imageGets += 1
        if (imageGets > 1) imageStatus = 'ready'
        return Promise.resolve({
          data: {
            id: 'img-1',
            status: imageStatus,
            downloadPercent: imageStatus === 'ready' ? 100 : 30,
          },
        })
      }
      if (String(url).includes('/tasks/task-1')) {
        return Promise.resolve({ data: { status: 'completed', error: null } })
      }
      return Promise.resolve({ data: {} })
    }) as typeof api.get
    api.post = mock((url: string) => {
      if (String(url).includes('/templates/deploy')) {
        return Promise.resolve({
          data: {
            status: 'provisioning',
            imageId: null,
            taskID: 'task-1',
            vm: provisionVm(),
          },
        })
      }
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post

    const store = useCreateProgressStore()
    const pending = store.followTemplate({
      name: 'alma',
      request: { templateId: 'tpl', vmName: 'alma', inputs: {}, cpuCount: 2, memoryMB: 2048 },
      result: { status: 'downloading', imageId: 'img-1', vm: null },
    })
    expect(store.jobs[0]?.phase).toBe('downloading')
    expect(store.mergeInto([]).some((row) => row.vm.name === 'alma' && row.createPhase === 'downloading')).toBe(true)
    await pending
    expect(store.jobs).toHaveLength(0)
    const home = useDeviceWorkloadsStore()
    expect(home.vmsFor(home.selfHostId || 'self').some((vm) => vm.id === 'vm-alma')).toBe(true)
    expect((api.post as ReturnType<typeof mock>).mock.calls.length).toBe(1)
  })

  test('image error stays on the list as failed', async () => {
    api.get = mock((url: string) => {
      if (String(url).includes('/images/img-bad')) {
        return Promise.resolve({
          data: { id: 'img-bad', status: 'error', error: 'checksum mismatch' },
        })
      }
      return Promise.resolve({ data: {} })
    }) as typeof api.get

    const store = useCreateProgressStore()
    await store.followTemplate({
      name: 'box',
      request: { templateId: 'tpl', vmName: 'box', inputs: {} },
      result: { status: 'downloading', imageId: 'img-bad', vm: null },
    })
    expect(store.jobs[0]?.phase).toBe('error')
    expect(store.jobs[0]?.detail).toContain('checksum')
    expect(useToastStore().toasts.some((t) => t.type === 'error')).toBe(true)
    expect(store.mergeInto([])[0]?.createPhase).toBe('error')
  })

  test('provisioning overlays a real VM until the task completes', async () => {
    api.get = mock((url: string) => {
      if (String(url).includes('/tasks/t1')) {
        return Promise.resolve({ data: { status: 'completed', error: null } })
      }
      return Promise.resolve({ data: {} })
    }) as typeof api.get
    const store = useCreateProgressStore()
    const vm = provisionVm()
    const home = useDeviceWorkloadsStore()
    home.noteSelf({ hostId: 'desk', role: 'self' })
    home.putOne('desk', vm)
    const done = store.followVM({ vm, taskID: 't1', device: { hostId: 'desk', role: 'self' } })
    const merged = store.mergeInto(home.homeRows([{
      hostId: 'desk',
      role: 'self',
      reachability: 'ok',
      agentPort: 7778,
      displayName: 'Desk',
    } as never]))
    expect(merged.some((row) => row.createPhase === 'provisioning' && row.vm.id === 'vm-alma')).toBe(true)
    await done
    expect(store.jobs).toHaveLength(0)
  })
})
