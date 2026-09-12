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
    let vmState = 'provisioning'
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
      if (String(url).includes('/vms/vm-alma')) {
        if (imageStatus === 'ready') vmState = 'stopped'
        return Promise.resolve({ data: { ...provisionVm(), state: vmState } })
      }
      if (String(url).includes('/tasks/task-1')) {
        return Promise.resolve({ data: { status: 'completed', error: null } })
      }
      return Promise.resolve({ data: {} })
    }) as typeof api.get
    api.post = mock((url: string) => {
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post

    const store = useCreateProgressStore()
    const pending = store.followTemplate({
      name: 'alma',
      request: { templateId: 'tpl', vmName: 'alma', inputs: {}, cpuCount: 2, memoryMB: 2048 },
      result: { status: 'downloading', imageId: 'img-1', vm: provisionVm() },
    })
    expect(store.jobs[0]?.phase).toBe('downloading')
    expect(store.jobs[0]?.vmId).toBe('vm-alma')
    expect(store.mergeInto([]).some((row) => row.vm.id === 'vm-alma' && row.createPhase === 'downloading')).toBe(true)
    await pending
    expect(store.jobs).toHaveLength(0)
    const home = useDeviceWorkloadsStore()
    expect(home.vmsFor(home.selfHostId || 'self').some((vm) => vm.id === 'vm-alma')).toBe(true)
    expect((api.post as ReturnType<typeof mock>).mock.calls.length).toBe(0)
    expect(imageGets).toBeGreaterThan(0)
  })

  test('VM downloadPercent drives percent without GET /images', async () => {
    let vmGets = 0
    api.get = mock((url: string) => {
      if (String(url).includes('/images/')) {
        throw new Error(`unexpected image poll ${url}`)
      }
      if (String(url).includes('/vms/vm-alma')) {
        vmGets += 1
        if (vmGets === 1) {
          return Promise.resolve({
            data: { ...provisionVm(), pendingImageId: 'img-1', downloadPercent: 41 },
          })
        }
        return Promise.resolve({
          data: {
            ...provisionVm(),
            state: 'stopped',
            pendingImageId: null,
            downloadPercent: null,
          },
        })
      }
      return Promise.resolve({ data: {} })
    }) as typeof api.get
    api.post = mock((url: string) => {
      throw new Error(`unexpected POST ${url}`)
    }) as typeof api.post

    const store = useCreateProgressStore()
    await store.followTemplate({
      name: 'alma',
      request: { templateId: 'tpl', vmName: 'alma', inputs: {}, cpuCount: 2, memoryMB: 2048 },
      result: {
        status: 'downloading',
        imageId: 'img-1',
        vm: { ...provisionVm(), pendingImageId: 'img-1', downloadPercent: 41 },
      },
    })
    expect(store.jobs).toHaveLength(0)
    expect(vmGets).toBeGreaterThan(0)
    expect((api.post as ReturnType<typeof mock>).mock.calls.length).toBe(0)
  })

  test('mergeInto overlays application pull and start', () => {
    const store = useCreateProgressStore()
    const pulling = store.mergeInto([{
      vm: { ...provisionVm(), id: 'app-1', kind: 'Application', state: 'provisioning' },
      hostId: 'desk',
      label: 'Desk',
      role: 'self',
      reachable: true,
    }])
    expect(pulling[0]?.createPhase).toBe('pulling')
    expect(pulling[0]?.createDetail).toBe('Pulling image…')
    const starting = store.mergeInto([{
      vm: { ...provisionVm(), id: 'app-1', kind: 'Application', state: 'starting' },
      hostId: 'desk',
      label: 'Desk',
      role: 'self',
      reachable: true,
    }])
    expect(starting[0]?.createPhase).toBe('starting')
    expect(starting[0]?.createDetail).toBe('Starting…')
  })

  test('mergeInto uses downloadPercent from the VM row', () => {
    const store = useCreateProgressStore()
    const vm = { ...provisionVm(), pendingImageId: 'img-1', downloadPercent: 12 }
    const merged = store.mergeInto([{
      vm,
      hostId: 'desk',
      label: 'Desk',
      role: 'self',
      reachable: true,
    }])
    expect(merged[0]?.createPhase).toBe('downloading')
    expect(merged[0]?.createPercent).toBe(12)
  })

  test('image error stays on the list as failed', async () => {
    api.get = mock((url: string) => {
      if (String(url).includes('/images/img-bad')) {
        return Promise.resolve({
          data: { id: 'img-bad', status: 'error', error: 'checksum mismatch' },
        })
      }
      if (String(url).includes('/vms/')) {
        return Promise.resolve({
          data: { ...provisionVm(), id: 'vm-box', name: 'box', pendingImageId: 'img-bad' },
        })
      }
      return Promise.resolve({ data: {} })
    }) as typeof api.get

    const store = useCreateProgressStore()
    await store.followTemplate({
      name: 'box',
      request: { templateId: 'tpl', vmName: 'box', inputs: {} },
      result: { status: 'downloading', imageId: 'img-bad', vm: { ...provisionVm(), id: 'vm-box', name: 'box' } },
    })
    expect(store.jobs[0]?.phase).toBe('error')
    expect(store.jobs[0]?.vmId).toBe('vm-box')
    expect(store.jobs[0]?.detail).toContain('checksum')
    expect(useToastStore().toasts.some((t) => t.type === 'error')).toBe(true)
    expect(store.mergeInto([])[0]?.createPhase).toBe('error')
    expect(store.mergeInto([])[0]?.vm.id).toBe('vm-box')
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

  test('app create pending row then running toast', async () => {
    let state = 'provisioning'
    api.post = mock((url: string) => {
      expect(String(url)).toContain('/workloads/apply')
      return Promise.resolve({ data: { op: 'created', id: 'app-whoami' } })
    }) as typeof api.post
    api.get = mock((url: string) => {
      expect(String(url)).toContain('/vms/app-whoami')
      if (state === 'provisioning') {
        state = 'starting'
        return Promise.resolve({
          data: { ...provisionVm(), id: 'app-whoami', name: 'whoami', kind: 'Application', state: 'provisioning' },
        })
      }
      if (state === 'starting') {
        state = 'running'
        return Promise.resolve({
          data: { ...provisionVm(), id: 'app-whoami', name: 'whoami', kind: 'Application', state: 'starting' },
        })
      }
      return Promise.resolve({
        data: { ...provisionVm(), id: 'app-whoami', name: 'whoami', kind: 'Application', state: 'running' },
      })
    }) as typeof api.get

    const store = useCreateProgressStore()
    const pending = store.followApp({
      name: 'whoami',
      body: { kind: 'Application' },
      device: { hostId: 'desk', role: 'self' },
    })
    expect(store.jobs[0]?.phase).toBe('pulling')
    expect(store.mergeInto([])[0]?.vm.kind).toBe('Application')
    expect(store.mergeInto([])[0]?.createPhase).toBe('pulling')
    await pending
    expect(store.jobs).toHaveLength(0)
    expect(useToastStore().toasts.some((t) => t.type === 'success' && t.message.includes('whoami'))).toBe(true)
    const home = useDeviceWorkloadsStore()
    expect(home.vmsFor(home.selfHostId || 'desk').some((vm) => vm.id === 'app-whoami' && vm.state === 'running')).toBe(true)
  })

  test('app create failure stays on the list', async () => {
    api.post = mock(() => Promise.resolve({ data: { op: 'created', id: 'app-bad' } })) as typeof api.post
    api.get = mock(() => Promise.resolve({
      data: {
        ...provisionVm(),
        id: 'app-bad',
        name: 'bad',
        kind: 'Application',
        state: 'error',
        description: 'compose up failed',
      },
    })) as typeof api.get

    const store = useCreateProgressStore()
    await store.followApp({
      name: 'bad',
      body: { kind: 'Application' },
      device: { hostId: 'desk', role: 'self' },
    })
    expect(store.jobs[0]?.phase).toBe('error')
    expect(store.jobs[0]?.detail).toContain('compose up')
    expect(useToastStore().toasts.some((t) => t.type === 'error')).toBe(true)
    expect(store.mergeInto([])[0]?.createPhase).toBe('error')
    expect(store.mergeInto([])[0]?.vm.id).toBe('app-bad')
  })
})
