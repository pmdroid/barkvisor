import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import type { VM, CreateVMRequest, UpdateVMRequest, WorkloadSpec } from '../api/types'
import { apiErrorMessage } from '../api/errors'
import type { DeviceApiTarget } from '../utils/homeDeviceApi'
import { deviceVmsBasePath, isSelfDevice } from '../utils/homeDeviceApi'

export const useVMStore = defineStore('vms', () => {
  const vms = ref<VM[]>([])
  const loading = ref(false)
  const error = ref<string | null>(null)

  async function fetchAll() {
    loading.value = true
    error.value = null
    try {
      const { data } = await api.get('/vms')
      vms.value = data
    } catch (e: any) {
      error.value = apiErrorMessage(e, 'Failed to load VMs')
    } finally {
      loading.value = false
    }
  }

  async function fetchOne(id: string): Promise<VM> {
    const { data } = await api.get(`/vms/${id}`)
    const idx = vms.value.findIndex((v) => v.id === id)
    if (idx >= 0) vms.value[idx] = data
    else vms.value.push(data)
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
      if (keepLocal) vms.value.push(vm)
      return { vm, taskID }
    }
    if (keepLocal) vms.value.push(res.data)
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
    const idx = vms.value.findIndex((v) => v.id === id)
    if (idx >= 0) vms.value[idx] = data
    return data
  }

  async function detachUSB(id: string, deviceId: string) {
    const { data } = await api.delete(`/vms/${id}/usb/${encodeURIComponent(deviceId)}`)
    const idx = vms.value.findIndex((v) => v.id === id)
    if (idx >= 0) vms.value[idx] = data
    return data
  }

  async function remove(id: string, keepDisk = false): Promise<string | undefined> {
    const res = await api.delete(`/vms/${id}`, { params: { keepDisk } })
    if (res.status === 202) {
      // Background deletion — mark VM as deleting locally, poll will clean up
      const idx = vms.value.findIndex((v) => v.id === id)
      if (idx >= 0) vms.value[idx] = { ...vms.value[idx], state: 'deleting' }
      return res.data.taskID
    }
    vms.value = vms.value.filter((v) => v.id !== id)
    return undefined
  }

  async function update(id: string, body: UpdateVMRequest) {
    const { data } = await api.patch(`/vms/${id}`, body)
    const idx = vms.value.findIndex((v) => v.id === id)
    if (idx >= 0) vms.value[idx] = data
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
