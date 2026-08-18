import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import api from '../api/client'
import type { Disk, DiskUsage, StorageSummary } from '../api/types'
import { apiErrorMessage } from '../api/errors'

export const useDiskStore = defineStore('disks', () => {
  const disks = ref<Disk[]>([])
  const usages = ref<Record<string, DiskUsage>>({})
  const summary = ref<StorageSummary | null>(null)
  const loading = ref(false)
  const error = ref<string | null>(null)

  const byId = computed(() => {
    const map: Record<string, Disk> = {}
    for (const d of disks.value) map[d.id] = d
    return map
  })

  const unattached = computed(() => disks.value.filter(d => !d.vmId))

  async function fetchAll(opts: { withUsage?: boolean } = {}) {
    loading.value = true
    error.value = null
    try {
      const { data } = await api.get<Disk[]>('/disks')
      disks.value = data
      if (opts.withUsage) {
        await fetchUsages(data.map(d => d.id))
      }
    } catch (e: unknown) {
      error.value = apiErrorMessage(e, 'Failed to load disks')
    } finally {
      loading.value = false
    }
  }

  async function fetchUsages(ids?: string[]) {
    const target = ids ?? disks.value.map(d => d.id)
    const next: Record<string, DiskUsage> = { ...usages.value }
    await Promise.all(
      target.map(async id => {
        try {
          const { data } = await api.get<DiskUsage>(`/disks/${id}/usage`)
          next[id] = data
        } catch {
          /* ignore per-disk usage failures */
        }
      }),
    )
    usages.value = next
  }

  async function fetchSummary() {
    try {
      const { data } = await api.get<StorageSummary>('/disks/summary')
      summary.value = data
    } catch {
      /* ignore */
    }
  }

  function applyList(next: Disk[]) {
    disks.value = next
  }

  function applyOne(disk: Disk) {
    const idx = disks.value.findIndex(d => d.id === disk.id)
    if (idx >= 0) disks.value[idx] = disk
    else disks.value.push(disk)
  }

  function applyRemove(id: string) {
    disks.value = disks.value.filter(d => d.id !== id)
    const { [id]: _, ...rest } = usages.value
    usages.value = rest
  }

  function applyUsage(id: string, usage: DiskUsage) {
    usages.value = { ...usages.value, [id]: usage }
  }

  function applySummary(next: StorageSummary) {
    summary.value = next
  }

  async function create(body: { name: string; sizeGB: number; format: string }): Promise<Disk> {
    const { data } = await api.post<Disk>('/disks', body)
    applyOne(data)
    await fetchSummary()
    return data
  }

  async function remove(id: string) {
    await api.delete(`/disks/${id}`)
    applyRemove(id)
    await fetchSummary()
  }

  async function resize(id: string, sizeGB: number) {
    await api.post(`/disks/${id}/resize`, { sizeGB })
    await Promise.all([fetchAll({ withUsage: true }), fetchSummary()])
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
    applySummary,
    create,
    remove,
    resize,
    getById,
  }
})
