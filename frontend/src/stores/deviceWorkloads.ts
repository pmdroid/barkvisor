import { defineStore } from 'pinia'
import { ref, watch } from 'vue'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot, UpdateVMRequest, VM, WorkloadSpec } from '../api/types'
import {
  canFetchDeviceWorkloads,
  deviceVmActionPath,
  deviceVmPath,
  deviceVmSpecPath,
  deviceVmUsbDevicePath,
  deviceVmUsbPath,
  deviceVmsBasePath,
  type DeviceApiTarget,
} from '../utils/homeDeviceApi'
import { hardwarePatchBody } from '../utils/editHome'
import { useDevicesStore } from './devices'
import { asArray, createHomeInventory, homeUnionRows } from './homeInventory'

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
  const inventory = createHomeInventory<VM>()
  const devices = useDevicesStore()
  const actionLoading = ref<Record<string, boolean>>({})

  watch(
    () => devices.selfDevice,
    (self) => {
      if (self) inventory.noteSelf(self)
    },
    { immediate: true },
  )

  function vmsFor(hostId: string): VM[] {
    return inventory.listFor(hostId)
  }

  function isActing(hostId: string, vmId: string): boolean {
    return Boolean(actionLoading.value[actionKey(hostId, vmId)])
  }

  async function fetchFor(device: DeviceApiTarget): Promise<void> {
    await inventory.fetchFor({
      device,
      canFetch: canFetchDeviceWorkloads(device),
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load Workloads',
      request: async () => {
        const { data } = await api.get<VM[]>(deviceVmsBasePath(device))
        return data
      },
      asList: asArray<VM>,
    })
  }

  async function replaceOne(device: DeviceApiTarget, vm: VM): Promise<void> {
    inventory.noteSelf(device)
    inventory.replaceOne(device.hostId, vm)
  }

  function vmFor(hostId: string, vmId: string): VM | undefined {
    return vmsFor(hostId).find((row) => row.id === vmId)
  }

  function removeOne(hostId: string, vmId: string): void {
    inventory.removeOne(hostId, vmId)
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
    return homeUnionRows(devices, vmsFor, canFetchDeviceWorkloads).map((row) => ({
      vm: row.item,
      hostId: row.hostId,
      label: row.label,
      role: row.role,
      reachable: row.reachable,
    }))
  }

  return {
    vmsByHost: inventory.dataByHost,
    selfHostId: inventory.selfHostId,
    fetchFor,
    fetchHomeAll,
    homeRows,
    vmsFor,
    vmFor,
    replaceOne,
    replaceList: inventory.replaceList,
    putOne: inventory.replaceOne,
    removeOne,
    isLoading: inventory.isLoading,
    errorFor: inventory.errorFor,
    isActing,
    refreshOne,
    update,
    fetchSpec,
    attachUSB,
    detachUSB,
    start,
    stop,
    restart,
    noteSelf: inventory.noteSelf,
  }
})
