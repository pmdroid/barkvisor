<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { storeToRefs } from 'pinia'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { HomeDeviceHealthSnapshot, SystemStats, VM } from '../api/types'
import AppButton from '../components/ui/AppButton.vue'
import DeviceCard from '../components/DeviceCard.vue'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useDiskStore } from '../stores/disks'
import { useToastStore } from '../stores/toast'
import { useVMStore } from '../stores/vms'
import { scopeRows } from '../utils/deviceScope'
import { formatTemperatureC, formatVolumeUsed } from '../utils/format'
import { isSelfDevice } from '../utils/homeDeviceApi'
import { isReachabilityOk, reachabilityHint, reachabilityLabel } from '../utils/homeDeviceHealth'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'
import { openWorkloadRow } from '../utils/workloadDetail'
import { opsStatusClass, opsStatusLabel, vmHealth } from '../utils/workloadHealth'

const router = useRouter()
const store = useVMStore()
const diskStore = useDiskStore()
const devices = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const homeWorkloads = useDeviceWorkloadsStore()
const toast = useToastStore()
const { summary: storageSummary } = storeToRefs(diskStore)
const stats = ref<SystemStats | null>(null)
const retrying = ref<Record<string, boolean>>({})

const scopedDevices = computed(() => scopeRows(devices.devices, deviceScope.selectedHostId))
const selectedHostId = ref<string | null>(null)

watch(
  scopedDevices,
  (rows) => {
    if (!rows.length) {
      selectedHostId.value = null
      return
    }
    if (!rows.some((row) => row.hostId === selectedHostId.value)) {
      const self = rows.find((row) => isSelfDevice(row))
      selectedHostId.value = (self ?? rows[0]).hostId
    }
  },
  { immediate: true },
)

const selectedDevice = computed(
  () => scopedDevices.value.find((row) => row.hostId === selectedHostId.value) ?? null,
)
const selectedReachable = computed(() =>
  selectedDevice.value ? isReachabilityOk(selectedDevice.value.reachability) : false,
)
const selectedIsSelf = computed(() =>
  selectedDevice.value ? isSelfDevice(selectedDevice.value) : false,
)
const selectedReachLabel = computed(() => reachabilityLabel(selectedDevice.value?.reachability))
const selectedReachHint = computed(() =>
  selectedDevice.value ? reachabilityHint(selectedDevice.value) : null,
)
const selectedPlatform = computed(() => {
  const os = selectedDevice.value?.platform?.os
  const arch = selectedDevice.value?.platform?.arch
  if (os && arch) return `${os} ${arch}`
  return os || arch || ''
})

const toolbarSub = computed(() => {
  if (deviceScope.isAll) return `${HOME_LABEL} overview`
  const row = scopedDevices.value[0]
  return row ? devices.deviceLabel(row) : DEVICE_LABEL
})

const selfTempLabel = computed(() => formatTemperatureC(stats.value?.metrics?.temperatureC))
const selfStorageLabel = computed(() => {
  const summary = storageSummary.value
  if (!summary || !summary.volumeTotalBytes) return null
  return formatVolumeUsed(summary.volumeTotalBytes, summary.volumeAvailableBytes)
})

type Chip = { key: string; label?: string; value: string }
const selectedChips = computed<Chip[]>(() => {
  const row = selectedDevice.value
  if (!row || !selectedReachable.value) return []
  if (selectedIsSelf.value && stats.value) {
    const chips: Chip[] = [
      { key: 'cpu', label: 'CPU', value: `${stats.value.hostCpuPercent.toFixed(0)}%` },
      {
        key: 'mem',
        label: 'Mem',
        value: `${(stats.value.hostMemoryUsedMB / 1024).toFixed(1)} / ${(stats.value.hostMemoryTotalMB / 1024).toFixed(0)} GB`,
      },
    ]
    if (selfTempLabel.value) chips.push({ key: 'temp', value: selfTempLabel.value })
    if (selfStorageLabel.value) chips.push({ key: 'storage', label: 'Storage', value: selfStorageLabel.value })
    return chips
  }
  const chips: Chip[] = []
  const cpu = row.resources?.cpuLoadPercent
  if (cpu != null) chips.push({ key: 'cpu', label: 'CPU', value: `${Math.round(cpu)}%` })
  const used = row.resources?.memoryUsedMB
  const total = row.resources?.memoryTotalMB
  if (used != null && total != null) {
    chips.push({
      key: 'mem',
      label: 'Mem',
      value: `${(used / 1024).toFixed(1)} / ${(total / 1024).toFixed(0)} GB`,
    })
  }
  return chips
})

type BoardBucket = 'running' | 'failed' | 'stopped'

function bucketOf(vm: VM): BoardBucket {
  const health = vmHealth(vm)
  if (health === 'running' || health === 'guest_ready' || health === 'starting') return 'running'
  if (health === 'failed' || health === 'degraded') return 'failed'
  return 'stopped'
}

const selectedVms = computed(() =>
  selectedDevice.value ? homeWorkloads.vmsFor(selectedDevice.value.hostId) : [],
)

const board = computed<Record<BoardBucket, VM[]>>(() => {
  const buckets: Record<BoardBucket, VM[]> = { running: [], failed: [], stopped: [] }
  for (const vm of selectedVms.value) buckets[bucketOf(vm)].push(vm)
  return buckets
})

const boardColumns: Array<{
  key: BoardBucket
  label: string
  headClass: string
  dotClass: string
}> = [
  { key: 'running', label: 'Running', headClass: 'c-ok', dotClass: 'ok' },
  { key: 'failed', label: 'Failed', headClass: 'c-bad', dotClass: 'bad' },
  { key: 'stopped', label: 'Stopped', headClass: 'c-off', dotClass: 'off' },
]

function emptyText(key: BoardBucket): string {
  if (key === 'failed') return selectedReachable.value ? 'No failures' : 'No failed workloads'
  if (key === 'running') return 'No running workloads'
  return 'No stopped workloads'
}

function selectDevice(row: HomeDeviceHealthSnapshot) {
  selectedHostId.value = row.hostId
}

function vmOs(vm: VM): string {
  return vm.vmType.startsWith('windows') ? 'Windows' : 'Linux'
}

function vmSpecs(vm: VM): string {
  const mem = vm.memoryMB >= 1024
    ? `${(vm.memoryMB / 1024).toFixed(vm.memoryMB % 1024 === 0 ? 0 : 1)} GB`
    : `${vm.memoryMB} MB`
  return `${vm.cpuCount} cores · ${mem}`
}

function vmStateClass(vm: VM): string {
  return opsStatusClass(vmHealth(vm))
}

function vmError(vm: VM): string | null {
  return vm.status?.healthError ?? null
}

function openVm(vm: VM) {
  const device = selectedDevice.value
  if (!device) return
  openWorkloadRow((path) => { router.push(path) }, {
    hostId: device.hostId,
    role: device.role,
    vm,
  })
}

async function retry(vm: VM) {
  const device = selectedDevice.value
  if (!device) return
  retrying.value = { ...retrying.value, [vm.id]: true }
  try {
    await homeWorkloads.start(device, vm.id)
  } catch (err) {
    toast.error(apiErrorMessage(err))
  } finally {
    retrying.value = { ...retrying.value, [vm.id]: false }
  }
}

async function fetchStats() {
  try {
    const { data } = await api.get('/system/stats')
    stats.value = data
  } catch {
  }
}

async function fetchStorage() {
  await Promise.all([diskStore.fetchAll(), diskStore.fetchSummary()]).catch(() => {})
}

async function refreshHomeWorkloads() {
  await devices.fetchHealth().catch(() => {})
  const list = devices.devices
  if (list.length === 0) {
    await store.fetchAll()
    return
  }
  await homeWorkloads.fetchHomeAll(list)
}

let pollTimer: number
onMounted(() => {
  void refreshHomeWorkloads()
  void fetchStats()
  void fetchStorage()
  pollTimer = window.setInterval(() => {
    void fetchStats()
    void refreshHomeWorkloads()
  }, 5000)
})
onUnmounted(() => clearInterval(pollTimer))
</script>

<template>
  <div class="ops-page">
    <div class="ops-toolbar">
      <h1>Dashboard</h1>
      <span class="ops-sub">{{ toolbarSub }}</span>
      <div class="ops-actions">
        <AppButton variant="ghost" icon="sliders" @click="router.push('/settings')">Customize</AppButton>
        <AppButton variant="primary" icon="plus" @click="router.push('/vms?create=1')">Create VM</AppButton>
      </div>
    </div>
    <div class="ops-body split">
      <section class="dash-devices">
        <div class="ops-sec-head">
          <h3>{{ DEVICE_LABEL }}s</h3>
          <span class="n">{{ scopedDevices.length }}</span>
          <span class="hint">Select a {{ DEVICE_LABEL }} to inspect</span>
        </div>
        <div class="dash-dev-list">
          <DeviceCard
            v-for="row in scopedDevices"
            :key="row.hostId"
            :device="row"
            selectable
            :selected="row.hostId === selectedHostId"
            :temp-label="row.role === 'self' ? selfTempLabel : null"
            :storage-label="row.role === 'self' ? selfStorageLabel : null"
            @click="selectDevice(row)"
          />
          <div v-if="!scopedDevices.length" class="dash-empty">
            No {{ DEVICE_LABEL }}s in this {{ HOME_LABEL }} yet
          </div>
        </div>
      </section>
      <section v-if="selectedDevice" class="dash-detail">
        <div class="dash-detail-head">
          <div>
            <h2>{{ devices.deviceLabel(selectedDevice) }}</h2>
            <div class="dash-detail-meta">
              <template v-if="selectedIsSelf">This {{ DEVICE_LABEL }} · </template>
              <template v-if="selectedPlatform">{{ selectedPlatform }} · </template>
              <span :class="selectedReachable ? 'ops-ok-text' : 'ops-bad-text'">{{ selectedReachLabel }}</span>
            </div>
          </div>
          <div class="dash-chips">
            <span v-if="!selectedReachable" class="dash-chip bad">
              <span class="ops-dot bad pulse"></span><b>{{ selectedReachLabel }}</b>
            </span>
            <span v-for="chip in selectedChips" :key="chip.key" class="dash-chip">
              <template v-if="chip.label">{{ chip.label }} </template><b>{{ chip.value }}</b>
            </span>
          </div>
        </div>
        <div v-if="!selectedReachable" class="ops-banner">
          <svg width="16" height="16" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M7 1.5L13 12H1z" stroke-linejoin="round"/><path d="M7 5.5v3" stroke-linecap="round"/><circle cx="7" cy="10.2" r=".7" fill="currentColor" stroke="none"/></svg>
          <div>
            <div class="ops-banner-title">{{ DEVICE_LABEL }} unreachable</div>
            <div class="ops-banner-sub">
              {{ selectedReachHint }} Showing last known state. Workloads on {{ devices.deviceLabel(selectedDevice) }} cannot be managed until it reconnects.
            </div>
          </div>
        </div>
        <div class="dash-board">
          <div v-for="col in boardColumns" :key="col.key" class="dash-col">
            <div class="dash-col-head" :class="col.headClass">
              <span
                class="ops-dot"
                :class="[col.dotClass, { pulse: col.key === 'failed' && board.failed.length > 0 }]"
              ></span>
              {{ col.label }}
              <span class="count">{{ board[col.key].length }}</span>
            </div>
            <div class="dash-col-body">
              <div
                v-for="vm in board[col.key]"
                :key="vm.id"
                class="dash-card"
                :class="{ failed: col.key === 'failed', dim: !selectedReachable }"
                @click="openVm(vm)"
              >
                <div class="dash-card-top">
                  <span class="dash-card-name">{{ vm.name }}</span>
                  <span class="dash-os">{{ vmOs(vm) }}</span>
                </div>
                <div class="dash-card-specs">{{ vmSpecs(vm) }}</div>
                <div v-if="col.key === 'failed' && vmError(vm)" class="dash-err">
                  <svg width="13" height="13" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M7 1.5L13 12H1z" stroke-linejoin="round"/><path d="M7 5.5v3" stroke-linecap="round"/><circle cx="7" cy="10.2" r=".7" fill="currentColor" stroke="none"/></svg>
                  {{ vmError(vm) }}
                </div>
                <div class="dash-card-foot">
                  <span class="dash-state" :class="vmStateClass(vm)">
                    <span class="ops-dot" :class="vmStateClass(vm)"></span>{{ opsStatusLabel(vmHealth(vm)) }}
                  </span>
                  <button
                    v-if="col.key === 'failed'"
                    class="dash-mini"
                    :disabled="retrying[vm.id]"
                    @click.stop="retry(vm)"
                  >{{ retrying[vm.id] ? 'Retrying' : 'Retry' }}</button>
                </div>
              </div>
              <div
                v-if="!board[col.key].length"
                class="dash-col-empty"
                :class="{ ok: col.key === 'failed' && selectedReachable }"
              >
                {{ emptyText(col.key) }}
              </div>
            </div>
          </div>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.dash-devices {
  width: 40%;
  min-width: 0;
  display: flex;
  flex-direction: column;
  min-height: 0;
}
.dash-detail {
  width: 60%;
  min-width: 0;
  display: flex;
  flex-direction: column;
  min-height: 0;
}
.dash-dev-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
  overflow-y: auto;
  padding-right: 2px;
}
.dash-empty {
  border: 1px dashed var(--line);
  border-radius: var(--radius);
  padding: 16px 10px;
  text-align: center;
  color: var(--text-dim);
  font-size: 11.5px;
}
.dash-detail-head {
  display: flex;
  align-items: flex-start;
  gap: 16px;
  margin-bottom: 12px;
}
.dash-detail-head h2 {
  font-size: 17px;
  font-weight: 700;
  letter-spacing: -0.01em;
}
.dash-detail-meta {
  color: var(--text-dim);
  font-size: 12px;
  margin-top: 3px;
}
.dash-chips {
  margin-left: auto;
  display: flex;
  gap: 6px;
  flex-wrap: wrap;
  justify-content: flex-end;
  max-width: 420px;
}
.dash-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 11px;
  color: var(--text-dim);
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 4px 8px;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.dash-chip b { color: var(--text); font-weight: 600; }
.dash-chip.bad {
  border-color: rgba(248,113,113,0.5);
  color: var(--red);
  background: rgba(248,113,113,0.08);
}
.dash-board {
  flex: 1;
  display: grid;
  grid-template-columns: 1fr 1fr 1fr;
  gap: 10px;
  min-height: 0;
}
.dash-col {
  background: rgba(255,255,255,0.015);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  display: flex;
  flex-direction: column;
  min-height: 0;
}
.dash-col-head {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 10px 12px;
  border-bottom: 1px solid var(--line);
  font-size: 10.5px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.dash-col-head .count {
  margin-left: auto;
  font-size: 10.5px;
  color: var(--text-dim);
  background: rgba(255,255,255,0.06);
  padding: 1px 7px;
  border-radius: 10px;
  font-variant-numeric: tabular-nums;
}
.dash-col-head.c-ok { color: var(--green); }
.dash-col-head.c-bad { color: var(--red); }
.dash-col-head.c-off { color: var(--text-dim); }
.dash-col-body {
  padding: 10px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  overflow-y: auto;
}
.dash-card {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 10px 11px;
  transition: border-color 0.12s;
  cursor: pointer;
}
.dash-card:hover { border-color: rgba(255,255,255,0.16); }
.dash-card-top { display: flex; align-items: center; gap: 8px; }
.dash-card-name { font-weight: 600; font-size: 13px; overflow-wrap: anywhere; }
.dash-os {
  margin-left: auto;
  font-size: 9.5px;
  font-weight: 700;
  color: var(--text-dim);
  border: 1px solid var(--line);
  padding: 2px 6px;
  border-radius: var(--radius);
  text-transform: uppercase;
  letter-spacing: 0.05em;
  white-space: nowrap;
}
.dash-card-specs {
  color: var(--text-dim);
  font-size: 11.5px;
  margin-top: 5px;
  font-variant-numeric: tabular-nums;
}
.dash-card-foot { display: flex; align-items: center; margin-top: 9px; }
.dash-state {
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  display: inline-flex;
  align-items: center;
  gap: 5px;
}
.dash-state.ok { color: var(--green); }
.dash-state.bad { color: var(--red); }
.dash-state.off { color: var(--text-dim); }
.dash-card.failed {
  border-color: rgba(248,113,113,0.55);
  background: rgba(248,113,113,0.07);
  box-shadow: 0 0 0 1px rgba(248,113,113,0.22), 0 6px 22px rgba(248,113,113,0.12);
}
.dash-err {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 9px;
  font-size: 11.5px;
  color: var(--red);
  background: rgba(248,113,113,0.12);
  border: 1px solid rgba(248,113,113,0.32);
  border-radius: var(--radius);
  padding: 6px 8px;
  font-weight: 500;
}
.dash-err svg { flex-shrink: 0; }
.dash-mini {
  margin-left: auto;
  font: inherit;
  font-size: 10.5px;
  font-weight: 600;
  color: var(--text);
  background: rgba(255,255,255,0.06);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 3px 9px;
  cursor: pointer;
}
.dash-mini:hover { border-color: var(--red); color: var(--red); }
.dash-mini:disabled { opacity: 0.4; pointer-events: none; }
.dash-col-empty {
  border: 1px dashed rgba(255,255,255,0.12);
  border-radius: var(--radius);
  padding: 16px 10px;
  text-align: center;
  color: var(--text-dim);
  font-size: 11.5px;
}
.dash-col-empty.ok {
  border-color: rgba(52,211,153,0.28);
  color: rgba(52,211,153,0.85);
}
.dash-card.dim { opacity: 0.55; }

:root[data-theme="light"] .dash-col { background: rgba(0,0,0,0.015); }
:root[data-theme="light"] .dash-col-head .count { background: rgba(0,0,0,0.06); }
:root[data-theme="light"] .dash-card:hover { border-color: rgba(0,0,0,0.2); }
:root[data-theme="light"] .dash-mini { background: rgba(0,0,0,0.05); }
:root[data-theme="light"] .dash-col-empty { border-color: rgba(0,0,0,0.14); }

@media (max-width: 900px) {
  .dash-devices,
  .dash-detail { width: 100%; }
  .dash-board { grid-template-columns: 1fr; }
}
</style>
