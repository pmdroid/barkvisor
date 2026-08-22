import { defineStore } from 'pinia'
import { computed } from 'vue'
import type { Disk, DiskUsage, StorageSummary } from '../api/types'
import { thisDeviceTarget } from './homeInventory'
import { useDeviceDisksStore } from './deviceDisks'
import { useDevicesStore } from './devices'

export const useDiskStore = defineStore('disks', () => {
  const home = useDeviceDisksStore()
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

  const disks = computed(() => home.disksFor(selfHostId()))
  const usages = computed(() => home.usagesFor(selfHostId()))
  const summary = computed(() => home.summaryFor(selfHostId()))
  const loading = computed(() => home.isLoading(selfHostId()))
  const error = computed(() => home.errorFor(selfHostId()))

  const byId = computed(() => {
    const map: Record<string, Disk> = {}
    for (const d of disks.value) map[d.id] = d
    return map
  })

  const unattached = computed(() => disks.value.filter(d => !d.vmId))

  async function fetchAll(opts: { withUsage?: boolean } = {}) {
    await home.fetchFor(selfTarget(), {
      usages: Boolean(opts.withUsage),
      summary: false,
    })
  }

  async function fetchUsages(ids?: string[]) {
    const target = ids ?? disks.value.map(d => d.id)
    await home.fetchUsages(selfTarget(), target)
  }

  async function fetchSummary() {
    await home.fetchSummary(selfTarget())
  }

  function applyList(next: Disk[]) {
    const hostId = rememberSelf()
    home.replaceList(hostId, next)
  }

  function applyOne(disk: Disk) {
    const hostId = rememberSelf()
    home.replaceOne(hostId, disk)
  }

  function applyRemove(id: string) {
    const hostId = rememberSelf()
    home.replaceList(hostId, home.disksFor(hostId).filter(d => d.id !== id))
    home.dropUsage(hostId, id)
  }

  function applyUsage(id: string, usage: DiskUsage) {
    home.replaceUsage(rememberSelf(), id, usage)
  }

  function clearUsages() {
    home.replaceUsages(rememberSelf(), {})
  }

  function applySummary(next: StorageSummary) {
    home.applySummary(rememberSelf(), next)
  }

  async function create(body: { name: string; sizeGB: number; format: string }): Promise<Disk> {
    return home.create(selfTarget(), body)
  }

  async function remove(id: string) {
    await home.remove(selfTarget(), id)
  }

  async function resize(id: string, sizeGB: number) {
    await home.resize(selfTarget(), id, sizeGB)
  }

  function getById(id: string | null | undefined): Disk | undefined {
    if (!id) return undefined
    return byId.value[id]
  }

  return {
    disks,
    usages,
    summary,
    loading,
    error,
    byId,
    unattached,
    fetchAll,
    fetchUsages,
    fetchSummary,
    applyList,
    applyOne,
    applyRemove,
    applyUsage,
    clearUsages,
    applySummary,
    create,
    remove,
    resize,
    getById,
  }
})
