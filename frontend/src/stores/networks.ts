import { defineStore } from 'pinia'
import { computed } from 'vue'
import type { Network, NetworkModeName } from '../api/types'
import { thisDeviceTarget } from './homeInventory'
import { useDeviceNetworksStore } from './deviceNetworks'
import { useDevicesStore } from './devices'

export type NetworkWriteBody = {
  name: string
  mode: NetworkModeName
  bridge?: string
  dnsServer?: string
}

export const useNetworkStore = defineStore('networks', () => {
  const home = useDeviceNetworksStore()
  const devices = useDevicesStore()

  function selfTarget() {
    return thisDeviceTarget(devices.selfDevice, home.selfHostId)
  }

  function selfHostId(): string {
    return selfTarget().hostId
  }

  function rememberSelf(): string {
    const target = selfTarget()
    home.noteSelf(target)
    return target.hostId
  }

  const networks = computed(() => home.networksFor(selfHostId()))
  const loading = computed(() => home.isLoading(selfHostId()))
  const error = computed(() => home.errorFor(selfHostId()))

  const byId = computed(() => {
    const map: Record<string, Network> = {}
    for (const n of networks.value) map[n.id] = n
    return map
  })

  const defaultNAT = computed(
    () =>
      networks.value.find(n => n.mode === 'nat' && n.isDefault)
      ?? networks.value.find(n => n.mode === 'nat')
      ?? null,
  )

  async function fetchAll() {
    await home.fetchFor(selfTarget())
  }

  function applyOne(network: Network) {
    const hostId = rememberSelf()
    home.replaceOne(hostId, network)
  }

  function applyRemove(id: string) {
    home.removeOne(rememberSelf(), id)
  }

  async function create(body: NetworkWriteBody): Promise<Network> {
    return home.create(selfTarget(), body)
  }

  async function update(id: string, body: Partial<NetworkWriteBody>): Promise<Network> {
    return home.update(selfTarget(), id, body)
  }

  async function remove(id: string) {
    await home.remove(selfTarget(), id)
  }

  function getById(id: string | null | undefined): Network | undefined {
    if (!id) return undefined
    return byId.value[id]
  }

  return {
    networks,
    loading,
    error,
    byId,
    defaultNAT,
    fetchAll,
    applyOne,
    applyRemove,
    create,
    update,
    remove,
    getById,
  }
})
