<script setup lang="ts">
import { computed } from 'vue'
import type { HomeDeviceHealthSnapshot, WorkloadHealth } from '../api/types'
import {
  deviceWorkloadLine,
  isReachabilityOk,
  reachabilityCardClass,
  reachabilityHint,
  reachabilityLabel,
  reachabilityPillClass,
} from '../utils/homeDeviceHealth'
import { DEVICE_LABEL } from '../utils/terminology'
import { healthLabel } from '../utils/workloadHealth'

const props = defineProps<{
  device: HomeDeviceHealthSnapshot
}>()

const reachable = computed(() => isReachabilityOk(props.device.reachability))
const reachHint = computed(() => reachabilityHint(props.device))
const reachLabel = computed(() => reachabilityLabel(props.device.reachability))
const reachPill = computed(() => reachabilityPillClass(props.device.reachability))
const cardClass = computed(() => reachabilityCardClass(props.device.reachability))

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

const workloadLine = computed(() => deviceWorkloadLine(props.device))

const healthKeys: WorkloadHealth[] = ['running', 'starting', 'degraded', 'failed', 'stopped']
</script>

<template>
  <router-link
    class="device-card-link"
    :to="{ name: 'device-detail', params: { hostId: device.hostId } }"
    :aria-label="`Open workloads on ${title}`"
  >
  <article class="device-card" :class="cardClass">
    <div class="device-card-top">
      <div>
        <h3>{{ title }}</h3>
        <p class="device-card-meta">
          <span v-if="device.role === 'self'" class="device-chip self">This {{ DEVICE_LABEL }}</span>
          <span v-else class="device-chip">{{ DEVICE_LABEL }}</span>
          <span>{{ platformLabel }}</span>
        </p>
      </div>
      <span class="status-pill" :class="reachPill">
        {{ reachLabel }}
      </span>
    </div>
    <p class="device-card-workloads">{{ workloadLine }}</p>
    <p v-if="reachHint" class="device-card-hint">
      {{ reachHint }}
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
    <p class="device-card-open">Workloads</p>
  </article>
  </router-link>
</template>

<style scoped>
.device-card-link {
  display: block;
  min-width: 0;
  color: inherit;
  text-decoration: none;
}
.device-card-link:hover .device-card,
.device-card-link:focus-visible .device-card {
  border-color: var(--accent);
}
.device-card {
  background: var(--bg-card);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  padding: 16px 18px;
  min-width: 0;
  overflow: hidden;
}
.device-card.unreachable {
  border-color: rgba(248, 113, 113, 0.35);
}
.device-card.http-error {
  border-color: rgba(245, 158, 11, 0.4);
}
.device-card-top {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 12px;
}
.device-card h3 {
  margin: 0;
  font-size: 16px;
  font-weight: 700;
  letter-spacing: -0.02em;
  overflow-wrap: anywhere;
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
.device-card-open {
  margin: 12px 0 0;
  font-size: 12px;
  font-weight: 600;
  color: var(--accent);
}
</style>
