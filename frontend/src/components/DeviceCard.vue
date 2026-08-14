<script setup lang="ts">
import { computed } from 'vue'
import type { HomeDeviceHealthSnapshot, WorkloadHealth } from '../api/types'
import { DEVICE_LABEL } from '../utils/terminology'
import { healthLabel } from '../utils/workloadHealth'

const props = defineProps<{
  device: HomeDeviceHealthSnapshot
}>()

const reachable = computed(() => props.device.reachability === 'ok')

const title = computed(() => {
  if (props.device.displayName && props.device.displayName.trim()) return props.device.displayName
  return props.device.hostId
})

const platformLabel = computed(() => {
  const os = props.device.platform?.os
  const arch = props.device.platform?.arch
  if (os && arch) return `${os} · ${arch}`
  if (os || arch) return os || arch || ''
  return reachable.value ? DEVICE_LABEL : 'Unknown platform'
})

const workloadLine = computed(() => {
  if (!reachable.value) return 'Health unavailable'
  const count = props.device.workloadCount ?? 0
  const failed = props.device.healthCounts?.failed ?? 0
  if (failed > 0) return `${count} workloads · ${failed} failed`
  return `${count} workload${count === 1 ? '' : 's'}`
})

const healthKeys: WorkloadHealth[] = ['running', 'starting', 'degraded', 'failed', 'stopped']
</script>

<template>
  <article class="device-card" :class="{ unreachable: !reachable }">
    <div class="device-card-top">
      <div>
        <h3>{{ title }}</h3>
        <p class="device-card-meta">
          <span v-if="device.role === 'self'" class="device-chip self">This {{ DEVICE_LABEL }}</span>
          <span v-else class="device-chip">{{ DEVICE_LABEL }}</span>
          <span>{{ platformLabel }}</span>
        </p>
      </div>
      <span class="status-pill" :class="reachable ? 'running' : 'failed'">
        {{ reachable ? 'Reachable' : 'Unreachable' }}
      </span>
    </div>
    <p class="device-card-workloads">{{ workloadLine }}</p>
    <p v-if="!reachable" class="device-card-hint">
      This {{ DEVICE_LABEL.toLowerCase() }} is still running locally. The member did not answer.
    </p>
    <div v-else-if="device.healthCounts" class="device-card-health">
      <span
        v-for="key in healthKeys"
        :key="key"
        class="health-mini"
      >
        {{ device.healthCounts[key] ?? 0 }} {{ healthLabel(key) }}
      </span>
    </div>
    <p v-if="reachable && device.resources" class="device-card-res">
      <span v-if="device.resources.cpuLoadPercent != null">
        CPU {{ device.resources.cpuLoadPercent.toFixed(0) }}%
      </span>
      <span v-if="device.resources.memoryUsedMB != null && device.resources.memoryTotalMB">
        Mem {{ (device.resources.memoryUsedMB / 1024).toFixed(1) }} /
        {{ (device.resources.memoryTotalMB / 1024).toFixed(0) }} GB
      </span>
    </p>
  </article>
</template>

<style scoped>
.device-card {
  background: var(--bg-card);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  padding: 16px 18px;
}
.device-card.unreachable {
  border-color: rgba(248, 113, 113, 0.35);
}
.device-card-top {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 12px;
}
.device-card h3 {
  margin: 0;
  font-size: 16px;
  font-weight: 700;
  letter-spacing: -0.02em;
}
.device-card-meta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  margin: 6px 0 0;
  color: var(--text-dim);
  font-size: 12px;
}
.device-chip {
  display: inline-flex;
  padding: 2px 8px;
  border-radius: 2px;
  background: var(--bg-hover);
  color: var(--text-secondary);
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  font-size: 10px;
}
.device-chip.self {
  color: var(--green);
  background: var(--green-muted);
}
.device-card-workloads {
  margin: 14px 0 0;
  font-size: 13px;
  color: var(--text-secondary);
}
.device-card-hint {
  margin: 8px 0 0;
  font-size: 12px;
  color: var(--text-dim);
}
.device-card-health {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 10px;
}
.health-mini {
  font-size: 11px;
  color: var(--text-dim);
}
.device-card-res {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  margin: 10px 0 0;
  font-size: 12px;
  font-variant-numeric: tabular-nums;
  color: var(--text-secondary);
}
</style>
