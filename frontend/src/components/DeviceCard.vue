<script setup lang="ts">
import { computed, nextTick, ref } from 'vue'
import { useRouter } from 'vue-router'
import { saveDeviceName } from '../api/deviceName'
import { apiErrorMessage } from '../api/errors'
import type { HomeDeviceHealthSnapshot } from '../api/types'
import { useDevicesStore } from '../stores/devices'
import { useToastStore } from '../stores/toast'
import { canFetchDeviceWorkloads } from '../utils/homeDeviceApi'
import { isReachabilityOk, reachabilityHint, reachabilityLabel } from '../utils/homeDeviceHealth'
import { DEVICE_LABEL } from '../utils/terminology'
import AppButton from './ui/AppButton.vue'

const props = defineProps<{
  device: HomeDeviceHealthSnapshot
  selectable?: boolean
  selected?: boolean
  tempLabel?: string | null
  storageLabel?: string | null
}>()

const emit = defineEmits<{ click: [] }>()
const router = useRouter()
const devices = useDevicesStore()
const toast = useToastStore()
const canRename = computed(() => canFetchDeviceWorkloads(props.device))
const renaming = ref(false)
const nameDraft = ref('')
const nameSaving = ref(false)
const nameInput = ref<HTMLInputElement | null>(null)

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

async function startRename() {
  if (!canRename.value) return
  nameDraft.value = title.value
  renaming.value = true
  await nextTick()
  nameInput.value?.focus()
  nameInput.value?.select()
}

function cancelRename() {
  renaming.value = false
  nameDraft.value = ''
}

async function saveRename() {
  if (!canRename.value || nameSaving.value) return
  const name = nameDraft.value.trim()
  if (!name) {
    toast.error('Device name must not be empty')
    return
  }
  nameSaving.value = true
  try {
    const named = await saveDeviceName(name, props.device)
    nameDraft.value = named.displayName
    renaming.value = false
    await devices.fetchHealth({ force: true })
    toast.success('Device name saved')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not save Device name'))
  } finally {
    nameSaving.value = false
  }
}
</script>

<template>
  <div class="card-wrap" :class="{ 'can-rename': canRename && !renaming }">
    <form
      v-if="renaming"
      class="ops-dev rename-form"
      :class="{ selected, unreachable: !reachable }"
      @submit.prevent="saveRename"
    >
      <input
        ref="nameInput"
        v-model="nameDraft"
        class="rename-input"
        type="text"
        maxlength="64"
        autocomplete="off"
        spellcheck="false"
        aria-label="Device name"
        :disabled="nameSaving"
      />
      <div class="rename-actions">
        <AppButton variant="primary" :loading="nameSaving" :disabled="!nameDraft.trim()">Save</AppButton>
        <button type="button" class="rename-cancel" :disabled="nameSaving" @click="cancelRename">Cancel</button>
      </div>
    </form>
    <button
      v-else
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
    <button
      v-if="canRename && !renaming"
      type="button"
      class="rename-btn"
      @click="startRename"
    >Rename</button>
  </div>
</template>

<style scoped>
.card-wrap {
  position: relative;
}
.card-wrap.can-rename :deep(.ops-dev) {
  padding-right: 64px;
}
.rename-btn {
  position: absolute;
  top: 8px;
  right: 10px;
  z-index: 1;
  margin: 0;
  padding: 2px 0;
  border: 0;
  background: transparent;
  color: var(--text-dim);
  font: inherit;
  font-size: 11px;
  cursor: pointer;
}
.rename-btn:hover {
  color: var(--text);
}
.rename-form {
  display: flex;
  flex-direction: column;
  gap: 10px;
  cursor: default;
}
.rename-input {
  width: 100%;
  box-sizing: border-box;
  padding: 6px 10px;
  background: var(--bg-input, var(--bg));
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm, 6px);
  font-size: 14px;
  font-weight: 600;
}
.rename-actions {
  display: flex;
  align-items: center;
  gap: 8px;
}
.rename-cancel {
  margin: 0;
  padding: 0;
  border: 0;
  background: transparent;
  color: var(--text-dim);
  font: inherit;
  font-size: 12px;
  cursor: pointer;
}
.rename-cancel:hover {
  color: var(--text);
}
</style>
