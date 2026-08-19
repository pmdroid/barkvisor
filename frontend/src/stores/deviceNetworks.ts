import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import type {
  BridgeInfo,
  CurrentHostCapabilities,
  HomeDeviceHealthSnapshot,
  HostInterface,
  Network,
  NetworkModeName,
} from '../api/types'
import { parseSystemCapabilities } from '../utils/capabilitiesParse'
import {
  canCallDeviceAPI,
  deviceBridgesPath,
  deviceCapabilitiesPath,
  deviceInterfacesPath,
  deviceNetworkPath,
  deviceNetworksPath,
  type DeviceApiTarget,
} from '../utils/homeDeviceApi'
import { asArray, createHomeInventory, homeUnionRows } from './homeInventory'

export type NetworkWriteBody = {
  name: string
  mode: NetworkModeName
  bridge?: string
  dnsServer?: string
}

export type HomeNetworkRow = {
  network: Network
  hostId: string
  label: string
  role: string
  reachable: boolean
}

export const useDeviceNetworksStore = defineStore('deviceNetworks', () => {
  const inventory = createHomeInventory<Network>()
  const interfacesByHost = ref<Record<string, HostInterface[]>>({})
  const bridgesByHost = ref<Record<string, BridgeInfo[]>>({})
  const capsByHost = ref<Record<string, CurrentHostCapabilities>>({})
  const contextSeqByHost: Record<string, number> = {}

  function networksFor(hostId: string): Network[] {
    return inventory.listFor(hostId)
  }

  function interfacesFor(hostId: string): HostInterface[] {
    return interfacesByHost.value[hostId] ?? []
  }

  function bridgesFor(hostId: string): BridgeInfo[] {
    return bridgesByHost.value[hostId] ?? []
  }

  function capsFor(hostId: string): CurrentHostCapabilities | null {
    return capsByHost.value[hostId] ?? null
  }

  async function fetchFor(device: DeviceApiTarget): Promise<void> {
    await inventory.fetchFor({
      device,
      canFetch: canCallDeviceAPI(device),
      unreachablePolicy: 'keepLastKnown',
      loadError: 'Unable to load networks',
      request: async () => {
        const { data } = await api.get<Network[]>(deviceNetworksPath(device))
        return data
      },
      asList: asArray<Network>,
    })
  }

  async function fetchContext(device: DeviceApiTarget): Promise<void> {
    const hostId = device.hostId
    const seq = (contextSeqByHost[hostId] ?? 0) + 1
    contextSeqByHost[hostId] = seq
    if (!canCallDeviceAPI(device)) return
    try {
      const [ifaces, bridges, caps] = await Promise.all([
        api.get<HostInterface[]>(deviceInterfacesPath(device)).catch(() => ({ data: [] as HostInterface[] })),
        api.get<BridgeInfo[]>(deviceBridgesPath(device)).catch(() => ({ data: [] as BridgeInfo[] })),
        api.get(deviceCapabilitiesPath(device)).catch(() => ({ data: null })),
      ])
      if (seq !== contextSeqByHost[hostId]) return
      interfacesByHost.value = { ...interfacesByHost.value, [hostId]: asArray<HostInterface>(ifaces.data) }
      bridgesByHost.value = { ...bridgesByHost.value, [hostId]: asArray<BridgeInfo>(bridges.data) }
      if (caps.data) {
        capsByHost.value = { ...capsByHost.value, [hostId]: parseSystemCapabilities(caps.data) }
      }
    } catch {
      if (seq !== contextSeqByHost[hostId]) return
    }
  }

  async function fetchHomeAll(devices: HomeDeviceHealthSnapshot[]): Promise<void> {
    await Promise.all(devices.map(async (device) => {
      await fetchFor(device)
      await fetchContext(device)
    }))
  }

  function homeRows(devices: HomeDeviceHealthSnapshot[]): HomeNetworkRow[] {
    return homeUnionRows(devices, networksFor, canCallDeviceAPI).map((row) => ({
      network: row.item,
      hostId: row.hostId,
      label: row.label,
      role: row.role,
      reachable: row.reachable,
    }))
  }

  async function create(device: DeviceApiTarget, body: NetworkWriteBody): Promise<Network> {
    const { data } = await api.post<Network>(deviceNetworksPath(device), body)
    inventory.invalidateFetch(device.hostId)
    inventory.noteSelf(device)
    inventory.replaceOne(device.hostId, data)
    return data
  }

  async function update(
    device: DeviceApiTarget,
    id: string,
    body: Partial<NetworkWriteBody>,
  ): Promise<Network> {
    const { data } = await api.patch<Network>(deviceNetworkPath(device, id), body)
    inventory.invalidateFetch(device.hostId)
    inventory.noteSelf(device)
    inventory.replaceOne(device.hostId, data)
    return data
  }

  async function remove(device: DeviceApiTarget, id: string): Promise<void> {
    await api.delete(deviceNetworkPath(device, id))
    inventory.invalidateFetch(device.hostId)
    inventory.noteSelf(device)
    inventory.replaceList(device.hostId, networksFor(device.hostId).filter((row) => row.id !== id))
  }

  return {
    networksByHost: inventory.dataByHost,
    selfHostId: inventory.selfHostId,
    fetchFor,
    fetchContext,
    fetchHomeAll,
    homeRows,
    networksFor,
    interfacesFor,
    bridgesFor,
    capsFor,
    isLoading: inventory.isLoading,
    errorFor: inventory.errorFor,
    create,
    update,
    remove,
    replaceList: inventory.replaceList,
    replaceOne: inventory.replaceOne,
    removeOne: inventory.removeOne,
    noteSelf: inventory.noteSelf,
  }
})
