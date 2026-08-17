import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { HomeDeviceHealthSnapshot, UpdateVMRequest, VM, WorkloadSpec } from '../api/types'
import {
  canFetchDeviceWorkloads,
  deviceVmActionPath,
  deviceVmPath,
  deviceVmSpecPath,
  deviceVmUsbDevicePath,
  deviceVmUsbPath,
  deviceVmsBasePath,
  isSelfDevice,
} from '../utils/homeDeviceApi'
import { hardwarePatchBody } from '../utils/editHome'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'

export type HomeWorkloadRow = {
  vm: VM
  hostId: string
  label: string
  role: string
  reachable: boolean
}

function actionKey(hostId: string, vmId: string): string {
  return `${hostId}:${vmId}`
}

export const useDeviceWorkloadsStore = defineStore('deviceWorkloads', () => {
  const vmsByHost = ref<Record<string, VM[]>>({})
  const loadingByHost = ref<Record<string, boolean>>({})
  const errorByHost = ref<Record<string, string | null>>({})
  const actionLoading = ref<Record<string, boolean>>({})

  function vmsFor(hostId: string): VM[] {
    return vmsByHost.value[hostId] ?? []
  }

  function isLoading(hostId: string): boolean {
    return Boolean(loadingByHost.value[hostId])
  }

  function errorFor(hostId: string): string | null {
    return errorByHost.value[hostId] ?? null
  }

  function isActing(hostId: string, vmId: string): boolean {
    return Boolean(actionLoading.value[actionKey(hostId, vmId)])
  }

  async function fetchFor(device: HomeDeviceHealthSnapshot): Promise<void> {
    const hostId = device.hostId
    if (!canFetchDeviceWorkloads(device)) {
      // Keep last-known names (PAS-47). Never invent a list on first miss.
      if (!(hostId in vmsByHost.value)) {
        vmsByHost.value = { ...vmsByHost.value, [hostId]: [] }
      }
      errorByHost.value = { ...errorByHost.value, [hostId]: null }
      return
    }
    loadingByHost.value = { ...loadingByHost.value, [hostId]: true }
    try {
      const { data } = await api.get<VM[]>(deviceVmsBasePath(device))
      vmsByHost.value = { ...vmsByHost.value, [hostId]: Array.isArray(data) ? data : [] }
      errorByHost.value = { ...errorByHost.value, [hostId]: null }
    } catch (err) {
      errorByHost.value = {
        ...errorByHost.value,
        [hostId]: apiErrorMessage(err, 'Unable to load Workloads'),
      }
    } finally {
      loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
    }
  }

  async function replaceOne(device: HomeDeviceHealthSnapshot, vm: VM): Promise<void> {
    const hostId = device.hostId
    const current = vmsByHost.value[hostId] ?? []
    const idx = current.findIndex((row) => row.id === vm.id)
    const next = idx >= 0 ? current.map((row, i) => (i === idx ? vm : row)) : [...current, vm]
    vmsByHost.value = { ...vmsByHost.value, [hostId]: next }
  }

  function vmFor(hostId: string, vmId: string): VM | undefined {
    return vmsFor(hostId).find((row) => row.id === vmId)
  }

  function removeOne(hostId: string, vmId: string): void {
    const current = vmsByHost.value[hostId]
    if (!current?.some((row) => row.id === vmId)) return
    vmsByHost.value = {
      ...vmsByHost.value,
      [hostId]: current.filter((row) => row.id !== vmId),
    }
  }

  async function refreshOne(device: HomeDeviceHealthSnapshot, vmId: string): Promise<void> {
    const { data } = await api.get<VM>(deviceVmPath(device, vmId))
    await replaceOne(device, data)
  }

  async function update(
    device: HomeDeviceHealthSnapshot,
    vmId: string,
    body: UpdateVMRequest,
  ): Promise<VM> {
    const patch = hardwarePatchBody(body as UpdateVMRequest & { targetHostId?: string })
    const { data } = await api.patch<VM>(deviceVmPath(device, vmId), patch)
    await replaceOne(device, data)
    return data
  }

  async function fetchSpec(device: HomeDeviceHealthSnapshot, vmId: string): Promise<WorkloadSpec> {
    const { data } = await api.get<WorkloadSpec>(deviceVmSpecPath(device, vmId))
    return data
  }

  async function attachUSB(
    device: HomeDeviceHealthSnapshot,
    vmId: string,
    deviceId: string,
  ): Promise<VM> {
    const { data } = await api.post<VM>(deviceVmUsbPath(device, vmId), { deviceId })
    await replaceOne(device, data)
    return data
  }

  async function detachUSB(
    device: HomeDeviceHealthSnapshot,
    vmId: string,
    deviceId: string,
  ): Promise<VM> {
    const { data } = await api.delete<VM>(deviceVmUsbDevicePath(device, vmId, deviceId))
    await replaceOne(device, data)
    return data
  }

  async function runAction(
    device: HomeDeviceHealthSnapshot,
    vmId: string,
    action: 'start' | 'stop' | 'restart',
    body?: Record<string, unknown>,
  ): Promise<void> {
    const key = actionKey(device.hostId, vmId)
    actionLoading.value = { ...actionLoading.value, [key]: true }
    try {
      await api.post(deviceVmActionPath(device, vmId, action), body)
      await refreshOne(device, vmId)
    } finally {
      actionLoading.value = { ...actionLoading.value, [key]: false }
    }
  }

  async function start(device: HomeDeviceHealthSnapshot, vmId: string): Promise<void> {
    await runAction(device, vmId, 'start')
  }

  async function stop(
    device: HomeDeviceHealthSnapshot,
    vmId: string,
    { method = 'acpi' }: { method?: 'acpi' | 'force' } = {},
  ): Promise<void> {
    await runAction(device, vmId, 'stop', { force: method === 'force', method })
  }

  async function restart(device: HomeDeviceHealthSnapshot, vmId: string): Promise<void> {
    await runAction(device, vmId, 'restart')
  }

  async function fetchHomeAll(devices: HomeDeviceHealthSnapshot[]): Promise<void> {
    await Promise.all(devices.map((device) => fetchFor(device)))
  }

  function homeRows(devices: HomeDeviceHealthSnapshot[]): HomeWorkloadRow[] {
    const rows: HomeWorkloadRow[] = []
    for (const device of devices) {
      const reachable = canFetchDeviceWorkloads(device)
      const label = deviceDisplayLabel(device)
      const role = isSelfDevice(device) ? 'self' : String(device.role ?? 'member')
      for (const vm of vmsFor(device.hostId)) {
        rows.push({ vm, hostId: device.hostId, label, role, reachable })
      }
    }
    return rows
  }

  return {
    vmsByHost,
    fetchFor,
    fetchHomeAll,
    homeRows,
    vmsFor,
    vmFor,
    removeOne,
    isLoading,
    errorFor,
    isActing,
    refreshOne,
    update,
    fetchSpec,
    attachUSB,
    detachUSB,
    start,
    stop,
    restart,
  }
})
