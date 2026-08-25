<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { storeToRefs } from 'pinia'
import api from '../api/client'
import type { SystemStats } from '../api/types'
import DeviceCard from '../components/DeviceCard.vue'
import AppButton from '../components/ui/AppButton.vue'
import { useDevicesStore } from '../stores/devices'
import { useDiskStore } from '../stores/disks'
import { formatTemperatureC, formatVolumeUsed } from '../utils/format'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'

const router = useRouter()
const devices = useDevicesStore()
const diskStore = useDiskStore()
const { summary: storageSummary } = storeToRefs(diskStore)
const stats = ref<SystemStats | null>(null)

const selfTempLabel = computed(() => formatTemperatureC(stats.value?.metrics?.temperatureC))
const selfStorageLabel = computed(() => {
  const summary = storageSummary.value
  if (!summary || !summary.volumeTotalBytes) return null
  return formatVolumeUsed(summary.volumeTotalBytes, summary.volumeAvailableBytes)
})

async function fetchStats() {
  try {
    const { data } = await api.get('/system/stats')
    stats.value = data
  } catch {
  }
}

let pollTimer: number
onMounted(() => {
  devices.fetchHealth()
  void fetchStats()
  void diskStore.fetchSummary().catch(() => {})
  pollTimer = window.setInterval(() => {
    devices.fetchHealth()
    void fetchStats()
  }, 5000)
})
onUnmounted(() => clearInterval(pollTimer))
</script>

<template>
  <div class="ops-page">
    <div class="ops-toolbar">
      <h1>{{ DEVICE_LABEL }}s</h1>
      <span class="ops-sub">
        <template v-if="devices.totals">
          {{ devices.totals.reachable }} of {{ devices.totals.devices }} reachable
          <span v-if="devices.totals.unreachable > 0">
            · {{ devices.totals.unreachable }} unreachable
          </span>
          <template v-if="devices.totals.workloadCount != null">
            · {{ devices.totals.workloadCount }} workloads across this {{ HOME_LABEL }}
          </template>
        </template>
        <template v-else>
          Every {{ DEVICE_LABEL.toLowerCase() }} in this {{ HOME_LABEL }}
        </template>
      </span>
      <div class="ops-actions">
        <AppButton variant="primary" icon="plus" @click="router.push('/settings?tab=pairing')">
          Add a {{ DEVICE_LABEL }}
        </AppButton>
      </div>
    </div>
    <div class="ops-body">
      <p v-if="devices.error && !devices.report" class="devices-error">
        Could not load {{ DEVICE_LABEL.toLowerCase() }} health. This {{ DEVICE_LABEL.toLowerCase() }} is still running.
      </p>
      <div v-if="devices.devices.length" class="dev-rows">
        <DeviceCard
          v-for="row in devices.devices"
          :key="row.hostId"
          :device="row"
          :temp-label="row.role === 'self' ? selfTempLabel : null"
          :storage-label="row.role === 'self' ? selfStorageLabel : null"
        />
      </div>
      <div v-else class="dev-empty">No {{ DEVICE_LABEL }}s in this {{ HOME_LABEL }} yet</div>
    </div>
  </div>
</template>

<style scoped>
.devices-error {
  color: var(--text-secondary);
  font-size: 13px;
  margin: 0 0 12px;
}
.dev-rows {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(100%, 420px), 1fr));
  gap: 8px;
}
.dev-empty {
  border: 1px dashed var(--line);
  border-radius: var(--radius);
  padding: 16px 10px;
  text-align: center;
  color: var(--text-dim);
  font-size: 11.5px;
}
</style>
