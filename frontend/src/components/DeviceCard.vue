<script setup lang="ts">
import { computed } from 'vue'
import { useRouter } from 'vue-router'
import type { HomeDeviceHealthSnapshot } from '../api/types'
import { isReachabilityOk, reachabilityHint, reachabilityLabel } from '../utils/homeDeviceHealth'
import { DEVICE_LABEL } from '../utils/terminology'

const props = defineProps<{
  device: HomeDeviceHealthSnapshot
  selectable?: boolean
  selected?: boolean
  tempLabel?: string | null
  storageLabel?: string | null
}>()

const emit = defineEmits<{ click: [] }>()
const router = useRouter()

const reachable = computed(() => isReachabilityOk(props.device.reachability))
const reachLabel = computed(() => reachabilityLabel(props.device.reachability))
const reachHint = computed(() => reachabilityHint(props.device))

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

const failedCount = computed(() => props.device.healthCounts?.failed ?? 0)

const countLabel = computed(() => {
  const count = props.device.workloadCount
  if (count == null) return '—'
  return `${count} workload${count === 1 ? '' : 's'}`
})

const cpuPercent = computed(() => {
  if (!reachable.value) return null
  const value = props.device.resources?.cpuLoadPercent
  return value == null ? null : Math.round(value)
})

const memLabel = computed(() => {
  if (!reachable.value) return null
  const used = props.device.resources?.memoryUsedMB
  const total = props.device.resources?.memoryTotalMB
  if (used == null || total == null) return null
  return `${(used / 1024).toFixed(1)} / ${(total / 1024).toFixed(0)} GB`
})

const memPercent = computed(() => {
  if (!reachable.value) return 0
  const used = props.device.resources?.memoryUsedMB
  const total = props.device.resources?.memoryTotalMB
  if (used == null || !total) return 0
  return Math.min((used / total) * 100, 100)
})

function onClick() {
  emit('click')
  if (!props.selectable) {
    router.push({ name: 'device-detail', params: { hostId: props.device.hostId } })
  }
}
</script>

<template>
  <button
    type="button"
    class="ops-dev"
    :class="{ selected, unreachable: !reachable }"
    :aria-label="`${title} — Workloads`"
    :title="reachHint || undefined"
    @click="onClick"
  >
    <span class="ops-dev-top">
      <span class="ops-dot" :class="[reachable ? 'ok' : 'bad', { pulse: !reachable }]"></span>
      <span class="ops-dev-name">{{ title }}</span>
      <span v-if="device.role === 'self'" class="ops-dev-tag">This {{ DEVICE_LABEL }}</span>
      <span v-if="!reachable" class="ops-dev-tag-bad">{{ reachLabel }}</span>
      <span v-else-if="failedCount > 0" class="ops-dev-pill-bad">{{ failedCount }} failed</span>
      <span class="ops-dev-count">{{ countLabel }}</span>
    </span>
    <span class="ops-dev-meta">
      <template v-if="platformLabel">{{ platformLabel }} · </template>
      <span :class="reachable ? 'ops-ok-text' : 'ops-bad-text'">{{ reachLabel }}</span>
    </span>
    <span class="ops-meter">
      <span class="ops-m-label">CPU</span>
      <span class="ops-track">
        <span
          v-if="cpuPercent != null"
          class="ops-fill"
          :class="cpuPercent >= 60 ? 'hot' : 'cpu'"
          :style="{ width: cpuPercent + '%' }"
        ></span>
      </span>
      <span class="ops-m-val">{{ cpuPercent == null ? '—' : cpuPercent + '%' }}</span>
    </span>
    <span class="ops-meter">
      <span class="ops-m-label">MEM</span>
      <span class="ops-track">
        <span v-if="memLabel" class="ops-fill mem" :style="{ width: memPercent + '%' }"></span>
      </span>
      <span class="ops-m-val">{{ memLabel ?? '—' }}</span>
    </span>
    <span v-if="tempLabel || storageLabel" class="ops-dev-sub">
      <span v-if="tempLabel">{{ tempLabel }}</span>
      <span v-if="storageLabel">Storage {{ storageLabel }}</span>
    </span>
  </button>
</template>
