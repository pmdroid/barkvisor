import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { DeployTemplateRequest, DeployTemplateResponse, Image, TaskEvent, VM } from '../api/types'
import {
  deviceImagePath,
  deviceTaskPath,
  type DeviceApiTarget,
} from '../utils/homeDeviceApi'
import { imageRowDownloadPercent } from '../utils/imageProgress'
import {
  createPhaseHealth,
  PENDING_CREATE_ID_PREFIX,
  type CreateListPhase,
} from '../utils/workloadListStatus'
import { thisDeviceTarget } from './homeInventory'
import { useDeviceWorkloadsStore, type HomeWorkloadRow } from './deviceWorkloads'
import { useDevicesStore } from './devices'
import { useTemplateStore } from './templates'
import { useToastStore } from './toast'

export type CreateJob = {
  id: string
  name: string
  hostId: string
  label: string
  role: string
  reachable: boolean
  phase: CreateListPhase
  percent: number | null
  detail: string
  cpuCount: number
  memoryMB: number
  vmId?: string
}

function sleep(ms: number) {
  if (ms <= 0) return Promise.resolve()
  return new Promise<void>((resolve) => setTimeout(resolve, ms))
}

function newJobId() {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID()
  }
  return `${Date.now()}-${Math.random().toString(16).slice(2)}`
}

function pendingVM(job: CreateJob): VM {
  const now = new Date().toISOString()
  return {
    id: job.vmId ?? `${PENDING_CREATE_ID_PREFIX}${job.id}`,
    name: job.name,
    vmType: 'linux-arm64',
    state: job.phase === 'error' ? 'error' : 'provisioning',
    health: createPhaseHealth(job.phase),
    cpuCount: job.cpuCount,
    memoryMB: job.memoryMB,
    bootDiskId: '',
    isoId: null,
    isoIds: null,
    networkId: null,
    cloudInitPath: null,
    description: null,
    bootOrder: null,
    displayResolution: null,
    additionalDiskIds: null,
    uefi: false,
    tpmEnabled: false,
    macAddress: null,
    sharedPaths: null,
    portForwards: null,
    usbDevices: null,
    pendingChanges: false,
    createdAt: now,
    updatedAt: now,
  }
}

function jobRow(job: CreateJob): HomeWorkloadRow {
  return {
    vm: pendingVM(job),
    hostId: job.hostId,
    label: job.label,
    role: job.role,
    reachable: job.reachable,
    createPhase: job.phase,
    createDetail: job.detail,
    createPercent: job.percent,
  }
}

export const useCreateProgressStore = defineStore('createProgress', () => {
  const jobs = ref<CreateJob[]>([])
  const intervalMs = ref(1000)
  const aborted = new Set<string>()

  function placement(device?: DeviceApiTarget) {
    const devices = useDevicesStore()
    const home = useDeviceWorkloadsStore()
    const target = device ?? thisDeviceTarget(devices.selfDevice, home.selfHostId)
    const snap = devices.deviceByHostId(target.hostId) ?? devices.selfDevice
    return {
      target,
      hostId: target.hostId,
      label: snap ? devices.deviceLabel(snap) : '',
      role: target.role || snap?.role || 'self',
      reachable: target.role === 'self' || target.reachability === 'ok' || snap?.reachability === 'ok',
    }
  }

  function addJob(partial: Omit<CreateJob, 'id'>): CreateJob {
    const job: CreateJob = { id: newJobId(), ...partial }
    jobs.value = [...jobs.value, job]
    return job
  }

  function patchJob(id: string, fields: Partial<CreateJob>) {
    jobs.value = jobs.value.map((job) => (job.id === id ? { ...job, ...fields } : job))
  }

  function dropJob(id: string) {
    aborted.add(id)
    jobs.value = jobs.value.filter((job) => job.id !== id)
  }

  function cancelAll() {
    for (const job of jobs.value) aborted.add(job.id)
    jobs.value = []
  }

  function living(id: string) {
    return !aborted.has(id) && jobs.value.some((job) => job.id === id)
  }

  function imagePath(device: DeviceApiTarget | undefined, imageId: string) {
    return device ? deviceImagePath(device, imageId) : `/images/${imageId}`
  }

  function taskPath(device: DeviceApiTarget | undefined, taskID: string) {
    return device ? deviceTaskPath(device, taskID) : `/tasks/${taskID}`
  }

  function applyVM(device: DeviceApiTarget | undefined, vm: VM) {
    const home = useDeviceWorkloadsStore()
    const { target } = placement(device)
    home.noteSelf(target)
    home.putOne(target.hostId, vm)
  }

  function fail(id: string, message: string) {
    if (!living(id)) return
    patchJob(id, { phase: 'error', detail: message, percent: null })
    useToastStore().error(message)
  }

  async function waitImage(id: string, imageId: string, device: DeviceApiTarget | undefined) {
    for (let i = 0; i < 600; i++) {
      if (!living(id)) return
      const { data } = await api.get(imagePath(device, imageId))
      if (!living(id)) return
      const image = data as Image
      if (!image || typeof image !== 'object' || Array.isArray(image)) {
        await sleep(intervalMs.value)
        continue
      }
      if (image.status === 'ready') return
      if (image.status === 'error') {
        throw new Error(image.error || 'Image download failed')
      }
      if (image.status === 'decompressing') {
        patchJob(id, {
          phase: 'decompressing',
          percent: null,
          detail: 'Decompressing image',
        })
      } else {
        patchJob(id, {
          phase: 'downloading',
          percent: imageRowDownloadPercent(image),
          detail: 'Downloading image',
        })
      }
      await sleep(intervalMs.value)
    }
    throw new Error('Timed out waiting for the image download')
  }

  async function waitTask(id: string, taskID: string, device: DeviceApiTarget | undefined) {
    for (let i = 0; i < 600; i++) {
      if (!living(id)) return
      const { data } = await api.get(taskPath(device, taskID))
      if (!living(id)) return
      const event = data as TaskEvent
      if (event?.status === 'completed') return event
      if (event?.status === 'failed' || event?.status === 'cancelled') {
        throw new Error(event.error || 'Provisioning failed')
      }
      await sleep(intervalMs.value)
    }
    throw new Error('Timed out waiting for provisioning')
  }

  async function handleResult(
    id: string,
    request: DeployTemplateRequest,
    device: DeviceApiTarget | undefined,
    result: DeployTemplateResponse,
  ) {
    if (!living(id)) return
    if (result.status === 'downloading' && result.imageId) {
      patchJob(id, {
        phase: 'downloading',
        detail: 'Downloading image',
        percent: null,
      })
      await waitImage(id, result.imageId, device)
      if (!living(id)) return
      const next = await useTemplateStore().deploy(request, device)
      await handleResult(id, request, device, next)
      return
    }
    if (result.vm) {
      applyVM(device, result.vm)
      patchJob(id, { vmId: result.vm.id })
      if (result.status === 'provisioning' && result.taskID) {
        patchJob(id, {
          phase: 'provisioning',
          detail: 'Provisioning disk',
          percent: null,
        })
        await waitTask(id, result.taskID, device)
        if (!living(id)) return
        dropJob(id)
        return
      }
      dropJob(id)
      return
    }
    throw new Error('Create did not return a VM')
  }

  async function followTemplate(opts: {
    name: string
    request: DeployTemplateRequest
    device?: DeviceApiTarget
    result: DeployTemplateResponse
  }) {
    const place = placement(opts.device)
    const job = addJob({
      name: opts.name,
      hostId: place.hostId,
      label: place.label,
      role: place.role,
      reachable: place.reachable,
      phase: opts.result.status === 'downloading' ? 'downloading' : 'provisioning',
      percent: null,
      detail: opts.result.status === 'downloading' ? 'Downloading image' : 'Provisioning disk',
      cpuCount: opts.request.cpuCount ?? 0,
      memoryMB: opts.request.memoryMB ?? 0,
      vmId: opts.result.vm?.id,
    })
    if (opts.result.vm) applyVM(opts.device, opts.result.vm)
    try {
      await handleResult(job.id, opts.request, opts.device, opts.result)
    } catch (e: unknown) {
      fail(job.id, apiErrorMessage(e))
    }
  }

  async function followVM(opts: {
    vm: VM
    taskID?: string
    device?: DeviceApiTarget
  }) {
    if (!opts.taskID) return
    const place = placement(opts.device)
    applyVM(opts.device, opts.vm)
    const job = addJob({
      name: opts.vm.name,
      hostId: place.hostId,
      label: place.label,
      role: place.role,
      reachable: place.reachable,
      phase: 'provisioning',
      percent: null,
      detail: 'Provisioning disk',
      cpuCount: opts.vm.cpuCount,
      memoryMB: opts.vm.memoryMB,
      vmId: opts.vm.id,
    })
    try {
      await waitTask(job.id, opts.taskID, opts.device)
      if (living(job.id)) dropJob(job.id)
    } catch (e: unknown) {
      fail(job.id, apiErrorMessage(e))
    }
  }

  function mergeInto(rows: HomeWorkloadRow[]): HomeWorkloadRow[] {
    const overlaid = rows.map((row) => {
      const job = jobs.value.find((item) => item.vmId === row.vm.id)
      if (!job) return row
      return {
        ...row,
        createPhase: job.phase,
        createDetail: job.detail,
        createPercent: job.percent,
      }
    })
    const known = new Set(overlaid.map((row) => row.vm.id))
    const pending = jobs.value
      .filter((job) => {
        if (job.vmId && known.has(job.vmId)) return false
        return true
      })
      .map(jobRow)
    return [...pending, ...overlaid]
  }

  return {
    jobs,
    intervalMs,
    followTemplate,
    followVM,
    mergeInto,
    cancelAll,
  }
})
