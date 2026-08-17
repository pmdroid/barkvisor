import { defineStore } from 'pinia'
import { ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type {
  BridgeInfo,
  CurrentHostCapabilities,
  HomeDeviceHealthSnapshot,
  HostInterface,
  Network,
  NetworkModeName,
} from '../api/types'
import { parseSystemCapabilities } from '../utils/capabilitiesParse'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import {
  canCallDeviceAPI,
  deviceBridgesPath,
  deviceCapabilitiesPath,
  deviceInterfacesPath,
  deviceNetworkPath,
  deviceNetworksPath,
  isSelfDevice,
} from '../utils/homeDeviceApi'

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

function asNetworks(data: unknown): Network[] {
  return Array.isArray(data) ? (data as Network[]) : []
}

function asInterfaces(data: unknown): HostInterface[] {
  return Array.isArray(data) ? (data as HostInterface[]) : []
}

function asBridges(data: unknown): BridgeInfo[] {
  return Array.isArray(data) ? (data as BridgeInfo[]) : []
}

export const useDeviceNetworksStore = defineStore('deviceNetworks', () => {
  const networksByHost = ref<Record<string, Network[]>>({})
  const interfacesByHost = ref<Record<string, HostInterface[]>>({})
  const bridgesByHost = ref<Record<string, BridgeInfo[]>>({})
  const capsByHost = ref<Record<string, CurrentHostCapabilities>>({})
  const loadingByHost = ref<Record<string, boolean>>({})
  const errorByHost = ref<Record<string, string | null>>({})
  const fetchSeqByHost: Record<string, number> = {}
  const contextSeqByHost: Record<string, number> = {}

  function networksFor(hostId: string): Network[] {
    return networksByHost.value[hostId] ?? []
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

  function isLoading(hostId: string): boolean {
    return Boolean(loadingByHost.value[hostId])
  }

  function errorFor(hostId: string): string | null {
    return errorByHost.value[hostId] ?? null
  }

  function replaceList(hostId: string, networks: Network[]): void {
    networksByHost.value = { ...networksByHost.value, [hostId]: networks }
  }

  function replaceOne(hostId: string, network: Network): void {
    const current = networksFor(hostId)
    const idx = current.findIndex((row) => row.id === network.id)
    const next = idx >= 0 ? current.map((row, i) => (i === idx ? network : row)) : [...current, network]
    replaceList(hostId, next)
  }

  async function fetchFor(device: HomeDeviceHealthSnapshot): Promise<void> {
    const hostId = device.hostId
    const seq = (fetchSeqByHost[hostId] ?? 0) + 1
    fetchSeqByHost[hostId] = seq
    if (!canCallDeviceAPI(device)) {
      // Keep last-known names (PAS-47). Never invent Default NAT on first miss.
      if (!(hostId in networksByHost.value)) {
        replaceList(hostId, [])
      }
      errorByHost.value = { ...errorByHost.value, [hostId]: null }
      loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
      return
    }
    loadingByHost.value = { ...loadingByHost.value, [hostId]: true }
    try {
      const { data } = await api.get<Network[]>(deviceNetworksPath(device))
      if (seq !== fetchSeqByHost[hostId]) return
      replaceList(hostId, asNetworks(data))
      errorByHost.value = { ...errorByHost.value, [hostId]: null }
    } catch (err) {
      if (seq !== fetchSeqByHost[hostId]) return
      errorByHost.value = {
        ...errorByHost.value,
        [hostId]: apiErrorMessage(err, 'Unable to load networks'),
      }
    } finally {
      if (seq === fetchSeqByHost[hostId]) {
        loadingByHost.value = { ...loadingByHost.value, [hostId]: false }
      }
    }
  }

  async function fetchContext(device: HomeDeviceHealthSnapshot): Promise<void> {
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
      interfacesByHost.value = { ...interfacesByHost.value, [hostId]: asInterfaces(ifaces.data) }
      bridgesByHost.value = { ...bridgesByHost.value, [hostId]: asBridges(bridges.data) }
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
    const rows: HomeNetworkRow[] = []
    for (const device of devices) {
      const reachable = canCallDeviceAPI(device)
      const label = deviceDisplayLabel(device)
      const role = isSelfDevice(device) ? 'self' : String(device.role ?? 'member')
      for (const network of networksFor(device.hostId)) {
        rows.push({ network, hostId: device.hostId, label, role, reachable })
      }
    }
    return rows
  }

  async function create(device: HomeDeviceHealthSnapshot, body: NetworkWriteBody): Promise<Network> {
    const { data } = await api.post<Network>(deviceNetworksPath(device), body)
    replaceOne(device.hostId, data)
    return data
  }

  async function update(
    device: HomeDeviceHealthSnapshot,
    id: string,
    body: Partial<NetworkWriteBody>,
  ): Promise<Network> {
    const { data } = await api.patch<Network>(deviceNetworkPath(device, id), body)
    replaceOne(device.hostId, data)
    return data
  }

  async function remove(device: HomeDeviceHealthSnapshot, id: string): Promise<void> {
    await api.delete(deviceNetworkPath(device, id))
    replaceList(device.hostId, networksFor(device.hostId).filter((row) => row.id !== id))
  }

  return {
    networksByHost,
    fetchFor,
    fetchContext,
    fetchHomeAll,
    homeRows,
    networksFor,
    interfacesFor,
    bridgesFor,
    capsFor,
    isLoading,
    errorFor,
    create,
    update,
    remove,
  }
})
