<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { Line } from 'vue-chartjs'
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Filler,
} from 'chart.js'
import { apiErrorMessage } from '../api/errors'
import { saveDeviceName } from '../api/deviceName'
import api from '../api/client'
import type { HomeDeviceHealthSnapshot, SystemAbout, SystemStats, SystemStatsSample } from '../api/types'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import CreateVMDrawer from '../components/CreateVMDrawer.vue'
import AppButton from '../components/ui/AppButton.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import { useDeviceDisksStore } from '../stores/deviceDisks'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useDevicesStore } from '../stores/devices'
import { useToastStore } from '../stores/toast'
import {
  emptyDeviceStatsChartSeries,
  latestGpuPercent,
  mapStatsHistorySamples,
  shouldFetchDeviceStatsHistory,
} from '../utils/deviceStatsHistory'
import { canFetchDeviceWorkloads, deviceAboutPath, devicePath, deviceStatsHistoryPath } from '../utils/homeDeviceApi'
import { parseSystemAbout } from '../utils/systemAbout'
import {
  reachabilityHint,
  reachabilityLabel,
} from '../utils/homeDeviceHealth'
import { DEVICE_LABEL } from '../utils/terminology'
import { openWorkloadRow } from '../utils/workloadDetail'
import { opsStatusClass, opsStatusLabel, vmHealth } from '../utils/workloadHealth'
import { formatCores, formatMemoryMB, formatPortForwards, formatTemperatureC, formatVolumeUsed } from '../utils/format'
import { acceleratorLabel, listBackendBadge, vmBackend } from '../utils/workloadBackend'

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Filler)

const route = useRoute()
const router = useRouter()
const devices = useDevicesStore()
const workloads = useDeviceWorkloadsStore()
const disks = useDeviceDisksStore()
const toast = useToastStore()

const hostId = computed(() => String(route.params.hostId ?? ''))
const device = computed(() => devices.deviceByHostId(hostId.value))
const reachLabel = computed(() => reachabilityLabel(device.value?.reachability))
const reachHint = computed(() => (device.value ? reachabilityHint(device.value) : null))
const title = computed(() => {
  if (!device.value) return hostId.value
  return devices.deviceLabel(device.value)
})
const platformLabel = computed(() => {
  const os = device.value?.platform?.os
  const arch = device.value?.platform?.arch
  if (os && arch) return `${os} · ${arch}`
  return os || arch || ''
})
const vms = computed(() => workloads.vmsFor(hostId.value))
const listError = computed(() => workloads.errorFor(hostId.value))
const loadingList = computed(() => workloads.isLoading(hostId.value))
const healthReady = computed(() => devices.report !== null || Boolean(devices.error))
const listSettled = computed(() => workloads.hasList(hostId.value))
const showEmptyWorkloads = computed(() =>
  vms.value.length === 0 && !loadingList.value && !listError.value && listSettled.value,
)
const showLoadingWorkloads = computed(() =>
  !listSettled.value && loadingList.value && !listError.value && vms.value.length === 0,
)

const restartLoading = reactive<Record<string, boolean>>({})
const stopConfirm = ref<{ id: string; name: string; method: 'acpi' | 'force' } | null>(null)
const showCreate = ref(false)
const deviceAbout = ref<SystemAbout | null>(null)
const deviceStats = ref<SystemStats | null>(null)
const renaming = ref(false)
const nameDraft = ref('')
const nameSaving = ref(false)
const canRename = computed(() => {
  const row = device.value
  if (!row) return false
  return canFetchDeviceWorkloads(row)
})

const failedVms = computed(() => vms.value.filter((vm) => vmHealth(vm) === 'failed'))

function formatUptime(seconds: number | null | undefined): string {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return ''
  const mins = Math.floor(seconds / 60)
  if (mins < 1) return `${Math.floor(seconds)}s`
  const hours = Math.floor(mins / 60)
  if (hours < 1) return `${mins}m`
  const days = Math.floor(hours / 24)
  if (days < 1) return `${hours}h ${mins % 60}m`
  if (hours % 24 === 0) return `${days} day${days === 1 ? '' : 's'}`
  return `${days}d ${hours % 24}h`
}

const osFact = computed(() => {
  if (deviceAbout.value) return `${deviceAbout.value.platform} · ${deviceAbout.value.hostArch}`
  return platformLabel.value
})
const roleFact = computed(() => (device.value?.role === 'self' ? '' : 'Member'))
const cpuFact = computed(() => {
  const count = device.value?.resources?.cpuCount
  if (count == null) return ''
  const load = device.value?.resources?.cpuLoadPercent
  return load == null ? formatCores(count) : `${formatCores(count)} · ${load.toFixed(0)}% used`
})
const memoryFact = computed(() => {
  const total = device.value?.resources?.memoryTotalMB
  const used = device.value?.resources?.memoryUsedMB
  if (total == null) return ''
  if (used == null) return formatMemoryMB(total)
  return `${formatMemoryMB(total)} · ${formatMemoryMB(used)} used`
})
const storageFact = computed(() => {
  const summary = disks.summaryFor(hostId.value)
  if (!summary || !summary.volumeTotalBytes) return ''
  return formatVolumeUsed(summary.volumeTotalBytes, summary.volumeAvailableBytes)
})
const temperatureFact = computed(() => formatTemperatureC(deviceStats.value?.metrics?.temperatureC) ?? '')
const addressFact = computed(() => device.value?.agentHost || '')
const uptimeFact = computed(() => formatUptime(deviceAbout.value?.processUptimeSeconds))
const virtFact = computed(() => {
  if (deviceAbout.value?.accelerator) return acceleratorLabel(deviceAbout.value.accelerator)
  if (device.value?.features?.kvmDevice) return 'KVM'
  return ''
})
const virtAvailable = computed(() => Boolean(device.value?.features?.kvmDevice || deviceAbout.value?.accelerator))

const history = reactive(emptyDeviceStatsChartSeries())

function resetHistory() {
  const empty = emptyDeviceStatsChartSeries()
  history.labels = empty.labels
  history.cpu = empty.cpu
  history.memoryGB = empty.memoryGB
  history.memoryTotalGB = empty.memoryTotalGB
  history.gpu = empty.gpu
}

function applyHistory(series: ReturnType<typeof mapStatsHistorySamples>) {
  history.labels = series.labels
  history.cpu = series.cpu
  history.memoryGB = series.memoryGB
  history.memoryTotalGB = series.memoryTotalGB
  history.gpu = series.gpu
}

function makeSparkOpts(max?: number) {
  return {
    responsive: true,
    maintainAspectRatio: false,
    animation: false as const,
    scales: {
      x: { display: false },
      y: { display: false, beginAtZero: true, max },
    },
    plugins: { tooltip: { enabled: false }, legend: { display: false } },
    elements: {
      point: { radius: 0 },
      line: { tension: 0.4, borderWidth: 1.5 },
    },
  }
}

const cpuSparkOpts = computed(() => makeSparkOpts(100))
const memSparkOpts = computed(() =>
  makeSparkOpts(history.memoryTotalGB != null ? Math.ceil(history.memoryTotalGB) : undefined),
)
const gpuSparkOpts = computed(() => makeSparkOpts(100))

const cpuSparkData = computed(() => ({
  labels: history.labels,
  datasets: [{
    data: history.cpu,
    borderColor: 'rgba(0,144,248,0.5)',
    backgroundColor: 'rgba(0,144,248,0.06)',
    fill: true,
  }],
}))

const memSparkData = computed(() => ({
  labels: history.labels,
  datasets: [{
    data: history.memoryGB,
    borderColor: 'rgba(52,211,153,0.5)',
    backgroundColor: 'rgba(52,211,153,0.06)',
    fill: true,
  }],
}))

const gpuSparkData = computed(() => ({
  labels: history.labels,
  datasets: [{
    data: history.gpu,
    borderColor: 'rgba(168,85,247,0.55)',
    backgroundColor: 'rgba(168,85,247,0.08)',
    fill: true,
  }],
}))

const latestCpu = computed(() => {
  if (history.cpu.length) return history.cpu[history.cpu.length - 1]
  if (deviceStats.value) return deviceStats.value.hostCpuPercent
  return device.value?.resources?.cpuLoadPercent ?? null
})
const latestMemoryGB = computed(() => {
  if (history.memoryGB.length) return history.memoryGB[history.memoryGB.length - 1]
  const used = deviceStats.value?.hostMemoryUsedMB ?? device.value?.resources?.memoryUsedMB
  return used != null ? used / 1024 : null
})
const memoryTotalGB = computed(() => {
  if (history.memoryTotalGB != null) return history.memoryTotalGB
  const total = deviceStats.value?.hostMemoryTotalMB ?? device.value?.resources?.memoryTotalMB
  return total != null ? total / 1024 : null
})
const latestGpu = computed(() => latestGpuPercent(history.gpu))
const gpuSparkReady = computed(() => history.gpu.filter((value) => value != null).length > 1)

function failedBannerSub(): string {
  if (failedVms.value.length === 1) {
    const vm = failedVms.value[0]!
    const err = vm.status?.healthError
    return err ? `${vm.name} — ${err}` : `${vm.name} is down.`
  }
  return `${failedVms.value.map((vm) => vm.name).join(', ')} are down.`
}

function statusSub(vm: (typeof vms.value)[number]): string {
  if (vmHealth(vm) !== 'failed') return ''
  const err = vm.status?.healthError
  const emu = listBackendBadge(vmBackend(vm))
  return [err, emu?.label].filter(Boolean).join(' · ')
}

async function refreshAbout(row: HomeDeviceHealthSnapshot | null = device.value) {
  if (!row || !canFetchDeviceWorkloads(row)) {
    deviceAbout.value = null
    return
  }
  const host = row.hostId
  try {
    const { data } = await api.get(deviceAboutPath(row))
    if (hostId.value !== host) return
    deviceAbout.value = parseSystemAbout(data)
  } catch {
    if (hostId.value !== host) return
    deviceAbout.value = null
  }
}

async function refreshStats(row: HomeDeviceHealthSnapshot | null = device.value) {
  if (!row || !canFetchDeviceWorkloads(row)) {
    deviceStats.value = null
    return
  }
  const host = row.hostId
  try {
    const { data } = await api.get<SystemStats>(devicePath(row, '/system/stats'))
    if (hostId.value !== host) return
    deviceStats.value = data
  } catch {
    if (hostId.value !== host) return
    deviceStats.value = null
  }
}

async function refreshHistory(row: HomeDeviceHealthSnapshot | null = device.value) {
  if (!row || !shouldFetchDeviceStatsHistory(row)) {
    resetHistory()
    return
  }
  const host = row.hostId
  try {
    const { data } = await api.get<SystemStatsSample[]>(deviceStatsHistoryPath(row))
    if (hostId.value !== host) return
    applyHistory(mapStatsHistorySamples(Array.isArray(data) ? data : []))
  } catch {
    if (hostId.value !== host) return
  }
}

function clearHostTransientState() {
  stopConfirm.value = null
  renaming.value = false
  nameDraft.value = ''
  nameSaving.value = false
  for (const id of Object.keys(restartLoading)) {
    delete restartLoading[id]
  }
}

function startRename() {
  if (!device.value || !canRename.value) return
  nameDraft.value = title.value
  renaming.value = true
}

function cancelRename() {
  renaming.value = false
  nameDraft.value = ''
}

async function saveRename() {
  const row = device.value
  if (!row || !canRename.value || nameSaving.value) return
  const name = nameDraft.value.trim()
  if (!name) {
    toast.error('Device name must not be empty')
    return
  }
  nameSaving.value = true
  try {
    const named = await saveDeviceName(name, row)
    nameDraft.value = named.displayName
    renaming.value = false
    await devices.fetchHealth()
    toast.success('Device name saved')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not save Device name'))
  } finally {
    nameSaving.value = false
  }
}

async function refreshDevice(row: HomeDeviceHealthSnapshot | null = device.value) {
  if (!row) return
  await workloads.fetchFor(row)
  await refreshAbout(row)
  await refreshStats(row)
  await refreshHistory(row)
  if (canFetchDeviceWorkloads(row)) {
    await disks.fetchSummary(row)
  }
}

let refreshSeq = 0
async function refresh() {
  const seq = ++refreshSeq
  await devices.fetchHealth()
  if (seq !== refreshSeq) return
  await refreshDevice(devices.deviceByHostId(hostId.value))
}

let pollTimer: number
onMounted(() => {
  void refresh()
  pollTimer = window.setInterval(() => { void refresh() }, 5000)
})
onUnmounted(() => {
  refreshSeq += 1
  clearInterval(pollTimer)
})
watch(hostId, () => {
  clearHostTransientState()
  resetHistory()
  deviceAbout.value = null
  deviceStats.value = null
  void refresh()
})

async function doStart(id: string) {
  const row = device.value
  if (!row) return
  try {
    await workloads.start(row, id)
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  }
}

async function doRestart(id: string) {
  const row = device.value
  if (!row) return
  restartLoading[id] = true
  try {
    await workloads.restart(row, id)
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    restartLoading[id] = false
  }
}

function openWorkload(vm: (typeof vms.value)[number]) {
  if (!device.value) return
  openWorkloadRow((path) => { router.push(path) }, {
    hostId: device.value.hostId,
    role: device.value.role,
    vm,
  })
}

function requestStop(id: string, method: 'acpi' | 'force') {
  const vm = vms.value.find((row) => row.id === id)
  stopConfirm.value = { id, name: vm?.name || id, method }
}

async function doStop() {
  if (!stopConfirm.value || !device.value) return
  const { id, method } = stopConfirm.value
  try {
    await workloads.stop(device.value, id, { method })
    stopConfirm.value = null
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  }
}
</script>

<template>
  <div class="ops-page">
    <div class="ops-toolbar">
      <button class="back" type="button" @click="router.push('/devices')">
        <svg width="11" height="11" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 1.5L3 6l4.5 4.5"/></svg>
        {{ DEVICE_LABEL }}s
      </button>
      <form v-if="renaming && device" class="rename-form" @submit.prevent="saveRename">
        <input
          v-model="nameDraft"
          class="rename-input"
          type="text"
          maxlength="64"
          autocomplete="off"
          spellcheck="false"
          aria-label="Device name"
          :disabled="nameSaving"
        />
        <AppButton variant="primary" :loading="nameSaving" :disabled="!nameDraft.trim()">Save</AppButton>
        <button type="button" class="mini" :disabled="nameSaving" @click="cancelRename">Cancel</button>
      </form>
      <template v-else>
        <h1
          :class="{ renameable: canRename }"
          :title="canRename ? 'Rename this Device' : undefined"
          @click="canRename && startRename()"
        >{{ device ? title : hostId }}</h1>
        <button
          v-if="canRename"
          type="button"
          class="mini"
          @click="startRename"
        >Rename</button>
      </template>
      <span v-if="device" :class="device.reachability === 'ok' ? 'pill-ok' : 'pill-bad'">
        <span class="ops-dot" :class="device.reachability === 'ok' ? 'ok' : 'bad'"></span>
        {{ reachLabel }}
      </span>
      <span v-if="device && (platformLabel || roleFact)" class="ops-sub">
        {{ [platformLabel, roleFact].filter(Boolean).join(' · ') }}
      </span>
      <div v-if="device" class="ops-actions">
        <AppButton
          v-if="canFetchDeviceWorkloads(device)"
          variant="primary"
          icon="plus"
          @click="showCreate = true"
        >
          Create VM
        </AppButton>
      </div>
    </div>

    <div class="ops-body">
    <div v-if="!device && (devices.loading || !healthReady)" class="missing">
      <p>Loading {{ DEVICE_LABEL.toLowerCase() }}...</p>
    </div>

    <div v-else-if="!device" class="missing">
      <template v-if="devices.error">
        <h1>{{ DEVICE_LABEL }}s unavailable</h1>
        <p>
          Could not load {{ DEVICE_LABEL.toLowerCase() }} health.
          This {{ DEVICE_LABEL.toLowerCase() }} is still running.
        </p>
      </template>
      <template v-else>
        <h1>Device not found</h1>
        <p>This {{ DEVICE_LABEL.toLowerCase() }} is not in the Home list.</p>
      </template>
    </div>

    <template v-else-if="device">
      <div v-if="!canFetchDeviceWorkloads(device)" class="ops-banner">
        <svg width="16" height="16" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M7 1.5L13 12H1z" stroke-linejoin="round"/><path d="M7 5.5v3" stroke-linecap="round"/><circle cx="7" cy="10.2" r=".7" fill="currentColor" stroke="none"/></svg>
        <div>
          <div class="ops-banner-title">{{ reachLabel }}</div>
          <div class="ops-banner-sub">{{ reachHint }} Workload counts are not shown.</div>
        </div>
      </div>

      <div v-if="failedVms.length" class="ops-banner">
        <svg width="16" height="16" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M7 1.5L13 12H1z" stroke-linejoin="round"/><path d="M7 5.5v3" stroke-linecap="round"/><circle cx="7" cy="10.2" r=".7" fill="currentColor" stroke="none"/></svg>
        <div>
          <div class="ops-banner-title">
            <span class="ops-dot bad pulse"></span>
            {{ failedVms.length }} Workload{{ failedVms.length === 1 ? '' : 's' }} failed
          </div>
          <div class="ops-banner-sub">{{ failedBannerSub() }}</div>
        </div>
        <button
          v-if="failedVms.length === 1"
          type="button"
          class="mini go"
          :disabled="workloads.isActing(hostId, failedVms[0]!.id)"
          @click="doStart(failedVms[0]!.id)"
        >
          {{ workloads.isActing(hostId, failedVms[0]!.id) ? 'Starting...' : `Start ${failedVms[0]!.name}` }}
        </button>
      </div>

      <div v-if="shouldFetchDeviceStatsHistory(device)" class="stat-grid">
        <div class="dash-stat cpu">
          <div v-if="history.cpu.length > 1" class="dash-stat-spark">
            <Line :data="cpuSparkData" :options="cpuSparkOpts" />
          </div>
          <div class="dash-stat-content">
            <div class="dash-stat-top">
              <span class="dash-stat-number">{{ latestCpu == null ? '—' : latestCpu.toFixed(0) + '%' }}</span>
              <span class="dash-stat-trend" :class="latestCpu != null && latestCpu > 80 ? 'warn' : 'up'">device</span>
            </div>
            <div class="dash-stat-label">CPU</div>
          </div>
        </div>
        <div class="dash-stat mem">
          <div v-if="history.memoryGB.length > 1" class="dash-stat-spark">
            <Line :data="memSparkData" :options="memSparkOpts" />
          </div>
          <div class="dash-stat-content">
            <div class="dash-stat-top">
              <span class="dash-stat-number">
                <template v-if="latestMemoryGB == null">—</template>
                <template v-else>{{ latestMemoryGB.toFixed(1) }} <small>GB</small></template>
              </span>
              <span v-if="memoryTotalGB != null" class="dash-stat-trend up">/ {{ memoryTotalGB.toFixed(0) }} GB</span>
            </div>
            <div class="dash-stat-label">Memory</div>
          </div>
        </div>
        <div class="dash-stat gpu">
          <div v-if="gpuSparkReady" class="dash-stat-spark">
            <Line :data="gpuSparkData" :options="gpuSparkOpts" />
          </div>
          <div class="dash-stat-content">
            <div class="dash-stat-top">
              <span class="dash-stat-number">{{ latestGpu == null ? '—' : latestGpu.toFixed(0) + '%' }}</span>
              <span class="dash-stat-trend up">device</span>
            </div>
            <div class="dash-stat-label">GPU</div>
          </div>
        </div>
      </div>

      <div class="sheet about-sheet">
        <div class="sheet-head"><h3>Facts</h3></div>
        <div class="sheet-grid">
          <div v-if="osFact" class="fact">
            <span class="k">OS</span>
            <span class="v">{{ osFact }}</span>
          </div>
          <div v-if="roleFact" class="fact">
            <span class="k">Role</span>
            <span class="v">{{ roleFact }}</span>
          </div>
          <div v-if="cpuFact" class="fact">
            <span class="k">CPU</span>
            <span class="v">{{ cpuFact }}</span>
          </div>
          <div v-if="memoryFact" class="fact">
            <span class="k">Memory</span>
            <span class="v">{{ memoryFact }}</span>
          </div>
          <div v-if="storageFact" class="fact">
            <span class="k">Storage</span>
            <span class="v">{{ storageFact }}</span>
          </div>
          <div v-if="temperatureFact" class="fact">
            <span class="k">Temperature</span>
            <span class="v">{{ temperatureFact }}</span>
          </div>
          <div v-if="addressFact" class="fact">
            <span class="k">Address</span>
            <span class="v mono">{{ addressFact }}</span>
          </div>
          <div v-if="uptimeFact" class="fact">
            <span class="k">Uptime</span>
            <span class="v">{{ uptimeFact }}</span>
          </div>
          <div v-if="virtFact" class="fact">
            <span class="k">Virtualization</span>
            <span class="v">
              {{ virtFact }}
              <span v-if="virtAvailable" class="ops-ok-text">available</span>
            </span>
          </div>
          <div v-if="deviceAbout" class="fact">
            <span class="k">Agent</span>
            <span class="v">barkvisord {{ deviceAbout.version }}</span>
          </div>
        </div>
      </div>

      <template v-if="canFetchDeviceWorkloads(device)">
        <p v-if="listError" class="list-error">{{ listError }}</p>

        <EmptyState
          v-if="showEmptyWorkloads"
          icon="monitor"
          title="No workloads on this Device"
        />

        <p v-else-if="showLoadingWorkloads" class="list-loading">Loading workloads...</p>

        <div v-else-if="listSettled || vms.length > 0" class="sheet workloads-sheet">
        <div class="sheet-head"><h3>Workloads</h3><span class="n">{{ vms.length }}</span></div>
        <table>
          <thead>
            <tr><th>Name</th><th>OS</th><th>CPU · Mem</th><th>Ports</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
          <tr v-for="vm in vms" :key="vm.id" class="vm-row" :class="{ failed: vmHealth(vm) === 'failed' }" @click="openWorkload(vm)">
            <td>
              <div class="vm">{{ vm.name }}</div>
            </td>
            <td>{{ vm.vmType.startsWith('windows') ? 'Windows' : 'Linux' }}</td>
            <td class="num">{{ formatCores(vm.cpuCount) }} · {{ formatMemoryMB(vm.memoryMB) }}</td>
            <td class="ports">{{ formatPortForwards(vm.portForwards) }}</td>
            <td>
              <span
                class="state"
                :class="opsStatusClass(vmHealth(vm))"
                :title="vm.status?.healthError || undefined"
              >
                <span
                  class="ops-dot"
                  :class="[opsStatusClass(vmHealth(vm)), { pulse: vmHealth(vm) === 'failed' }]"
                ></span>
                {{ opsStatusLabel(vmHealth(vm)) }}
              </span>
              <div v-if="statusSub(vm)" class="row-sub ops-bad-text">{{ statusSub(vm) }}</div>
            </td>
            <td class="acts" @click.stop>
              <button
                v-if="vm.state === 'stopped' || vm.state === 'error'"
                type="button"
                class="mini go"
                :disabled="workloads.isActing(hostId, vm.id)"
                @click="doStart(vm.id)"
              >
                {{ workloads.isActing(hostId, vm.id) ? 'Starting...' : 'Start' }}
              </button>
              <template v-else-if="vm.state === 'running'">
                <button type="button" class="mini" :disabled="workloads.isActing(hostId, vm.id)" @click="requestStop(vm.id, 'acpi')">Stop</button>
                <button type="button" class="mini" :disabled="restartLoading[vm.id] || workloads.isActing(hostId, vm.id)" @click="doRestart(vm.id)">
                  {{ restartLoading[vm.id] ? 'Restarting...' : 'Restart' }}
                </button>
              </template>
            </td>
          </tr>
          </tbody>
        </table>
        </div>
      </template>
    </template>
    </div>

    <CreateVMDrawer
      v-if="showCreate && device"
      :initial-host-id="device.hostId"
      @close="showCreate = false"
      @created="showCreate = false; refresh()"
    />

    <ConfirmDialog
      v-if="stopConfirm"
      :title="stopConfirm.method === 'force' ? 'Force Stop Workload' : 'Stop Workload'"
      :message="`Are you sure you want to ${stopConfirm.method === 'force' ? 'force stop' : 'shut down'} ${stopConfirm.name}?${stopConfirm.method === 'force' ? ' This may cause data loss.' : ''}`"
      :confirm-label="stopConfirm.method === 'force' ? 'Force Stop' : 'Shutdown'"
      :danger="stopConfirm.method === 'force'"
      :loading="workloads.isActing(hostId, stopConfirm.id)"
      @confirm="doStop"
      @cancel="stopConfirm = null"
    />
  </div>
</template>

<style scoped>
.stat-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(240px, 100%), 1fr));
  gap: 10px;
  margin-bottom: 12px;
  min-width: 0;
}
.dash-stat {
  position: relative;
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  overflow: hidden;
  min-width: 0;
  min-height: 96px;
  border-left: 3px solid var(--accent);
}
.dash-stat.mem { border-left-color: var(--green); }
.dash-stat.gpu { border-left-color: #a855f7; }
.dash-stat-spark {
  position: absolute;
  inset: 0;
  pointer-events: none;
  opacity: 0.7;
}
.dash-stat-spark :deep(*) {
  position: absolute;
  inset: 0;
  width: 100% !important;
  height: 100% !important;
}
.dash-stat-content {
  position: relative;
  z-index: 1;
  padding: 14px;
}
.dash-stat-top {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 8px;
  margin-bottom: 8px;
}
.dash-stat-number {
  font-size: 24px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  letter-spacing: -0.03em;
  line-height: 1;
}
.dash-stat-number small {
  font-size: 14px;
  font-weight: 500;
  color: var(--text-secondary);
}
.dash-stat-trend {
  font-size: 11px;
  font-weight: 600;
  color: var(--text-dim);
  padding: 3px 8px;
  border-radius: 2px;
}
.dash-stat-trend.up {
  color: var(--green);
  background: var(--green-muted);
}
.dash-stat-trend.warn {
  color: var(--amber);
  background: var(--amber-muted);
}
.dash-stat-label {
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
}
.list-error,
.list-loading,
.missing p {
  color: var(--text-secondary);
  font-size: 13px;
  line-height: 1.5;
}
.list-error,
.list-loading { margin: 0 0 16px; }
.missing h1 {
  margin: 0 0 8px;
  font-size: 20px;
}
.vm-row { cursor: pointer; }
.vm-row:hover { background: var(--bg-hover); }
.about-sheet {
  margin-bottom: 14px;
}
.ops-banner {
  align-items: center;
}
.ops-banner .mini {
  margin-left: auto;
  flex-shrink: 0;
}
.pill-ok .ops-dot {
  background: #06251a;
}
.mono {
  font-family: var(--font-mono);
  font-size: 12px;
}
.renameable {
  cursor: pointer;
}
.renameable:hover {
  text-decoration: underline;
  text-underline-offset: 3px;
}
.rename-form {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.rename-input {
  width: min(240px, 42vw);
  padding: 6px 10px;
  background: var(--bg-input, var(--bg));
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm, 6px);
  font-size: 14px;
  font-weight: 600;
}
@media (max-width: 768px) {
  .stat-grid { grid-template-columns: 1fr; }
}
</style>
