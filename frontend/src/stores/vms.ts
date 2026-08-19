import { defineStore } from 'pinia'
import { computed } from 'vue'
import api from '../api/client'
import type { VM, CreateVMRequest, UpdateVMRequest, WorkloadSpec } from '../api/types'
import type { DeviceApiTarget } from '../utils/homeDeviceApi'
import { deviceVmsBasePath, isSelfDevice } from '../utils/homeDeviceApi'
import { thisDeviceTarget } from './homeInventory'
import { useDeviceWorkloadsStore } from './deviceWorkloads'
import { useDevicesStore } from './devices'

export const useVMStore = defineStore('vms', () => {
  const home = useDeviceWorkloadsStore()
  const devices = useDevicesStore()

  function selfTarget(): DeviceApiTarget {
    return thisDeviceTarget(devices.selfDevice, home.selfHostId)
  }

  function selfHostId(): string {
    return selfTarget().hostId
  }

  const vms = computed(() => home.vmsFor(selfHostId()))
  const loading = computed(() => home.isLoading(selfHostId()))
  const error = computed(() => home.errorFor(selfHostId()))

  function applyLocal(vm: VM): void {
    const target = selfTarget()
    home.noteSelf(target)
    home.putOne(target.hostId, vm)
  }

  async function fetchAll() {
    await home.fetchFor(selfTarget())
  }

  async function fetchOne(id: string): Promise<VM> {
    const { data } = await api.get(`/vms/${id}`)
    applyLocal(data)
    return data
  }

  async function create(
    req: CreateVMRequest,
    device?: DeviceApiTarget,
  ): Promise<{ vm: VM; taskID?: string }> {
    // Never send targetHostId — member requireLocalHost stays. Route by URL.
    const { targetHostId: _ignored, ...body } = req as CreateVMRequest & {
      targetHostId?: string
    }
    const path = device ? deviceVmsBasePath(device) : '/vms'
    const res = await api.post(path, body)
    const keepLocal = !device || isSelfDevice(device)
    if (res.status === 202) {
      const { vm, taskID } = res.data
      if (keepLocal) applyLocal(vm)
      return { vm, taskID }
    }
    if (keepLocal) applyLocal(res.data)
    return { vm: res.data }
  }

  async function start(id: string) {
    await api.post(`/vms/${id}/start`)
    await fetchOne(id)
  }

  async function stop(id: string, { method = 'acpi' }: { method?: 'acpi' | 'force' } = {}) {
    await api.post(`/vms/${id}/stop`, { force: method === 'force', method })
    await fetchOne(id)
  }

  async function restart(id: string) {
    await api.post(`/vms/${id}/restart`)
    await fetchOne(id)
  }

  async function detachISO(id: string, isoId?: string) {
    await api.post(`/vms/${id}/detach-iso`, isoId ? { isoId } : {})
    await fetchOne(id)
  }

  async function attachISO(id: string, isoId: string) {
    await api.post(`/vms/${id}/attach-iso`, { isoId })
    await fetchOne(id)
  }

  async function attachUSB(id: string, deviceId: string) {
    const { data } = await api.post(`/vms/${id}/usb`, { deviceId })
    applyLocal(data)
    return data
  }

  async function detachUSB(id: string, deviceId: string) {
    const { data } = await api.delete(`/vms/${id}/usb/${encodeURIComponent(deviceId)}`)
    applyLocal(data)
    return data
  }

  async function remove(id: string, keepDisk = false): Promise<string | undefined> {
    const res = await api.delete(`/vms/${id}`, { params: { keepDisk } })
    if (res.status === 202) {
      const current = vms.value.find((row) => row.id === id)
      if (current) applyLocal({ ...current, state: 'deleting' })
      return res.data.taskID
    }
    home.removeOne(selfHostId(), id)
    return undefined
  }

  async function update(id: string, body: UpdateVMRequest) {
    const { data } = await api.patch(`/vms/${id}`, body)
    applyLocal(data)
    return data
  }

  async function fetchSpec(id: string): Promise<WorkloadSpec> {
    const { data } = await api.get(`/vms/${id}/spec`)
    return data
  }

  async function putSpec(id: string, spec: WorkloadSpec): Promise<WorkloadSpec> {
    const { data } = await api.put(`/vms/${id}/spec`, spec)
    await fetchOne(id)
    return data
  }

  return {
    vms, loading, error, fetchAll, fetchOne, create, start, stop, restart,
    detachISO, attachISO, attachUSB, detachUSB, remove, update, fetchSpec, putSpec,
  }
})
