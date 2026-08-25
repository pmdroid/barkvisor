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
import api from '../api/client'
import type { CurrentHostCapabilities, HomeDeviceHealthSnapshot, HostGPUDevice, SystemAbout, SystemStatsSample } from '../api/types'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import CreateVMDrawer from '../components/CreateVMDrawer.vue'
import AppButton from '../components/ui/AppButton.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import StopButtonGroup from '../components/ui/StopButtonGroup.vue'
import UnsupportedHint from '../components/ui/UnsupportedHint.vue'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useDevicesStore } from '../stores/devices'
import { useToastStore } from '../stores/toast'
import { parseSystemCapabilities } from '../utils/capabilitiesParse'
import { GUEST_OLLAMA_PATH, GPU_SINGLE_DISPLAY_WARNING, gpuGroupMatesLabel, gpuHostOccupancyLabel, gpuPassthroughExplanation, gpuPassthroughSupported } from '../utils/gpuPassthrough'
import {
  emptyDeviceStatsChartSeries,
  mapStatsHistorySamples,
  shouldFetchDeviceStatsHistory,
} from '../utils/deviceStatsHistory'
import { canFetchDeviceWorkloads, deviceAboutPath, deviceCapabilitiesPath, deviceGpuDevicesPath, deviceStatsHistoryPath } from '../utils/homeDeviceApi'
import { parseSystemAbout } from '../utils/systemAbout'
import {
  deviceResourcesLine,
  deviceWorkloadLine,
  reachabilityHint,
  reachabilityLabel,
  reachabilityPillClass,
} from '../utils/homeDeviceHealth'
import { DEVICE_LABEL } from '../utils/terminology'
import { openWorkloadRow } from '../utils/workloadDetail'
import { healthLabel, healthPillClass, vmHealth } from '../utils/workloadHealth'

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Filler)

const route = useRoute()
const router = useRouter()
const devices = useDevicesStore()
const workloads = useDeviceWorkloadsStore()
const toast = useToastStore()

const hostId = computed(() => String(route.params.hostId ?? ''))
const device = computed(() => devices.deviceByHostId(hostId.value))
const reachLabel = computed(() => reachabilityLabel(device.value?.reachability))
const reachPill = computed(() => reachabilityPillClass(device.value?.reachability))
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
const deviceCaps = ref<CurrentHostCapabilities | null>(null)
const hostGPUs = ref<HostGPUDevice[]>([])
const deviceAbout = ref<SystemAbout | null>(null)
const aboutReady = ref(false)

const gpuReady = computed(() => gpuPassthroughSupported(deviceCaps.value))
const gpuExplanation = computed(() => gpuPassthroughExplanation(deviceCaps.value))
const workloadLine = computed(() => (device.value ? deviceWorkloadLine(device.value) : ''))
const resourcesLine = computed(() => (device.value ? deviceResourcesLine(device.value) : null))

const history = reactive(emptyDeviceStatsChartSeries())

function resetHistory() {
  const empty = emptyDeviceStatsChartSeries()
  history.labels = empty.labels
  history.cpu = empty.cpu
  history.memoryGB = empty.memoryGB
  history.memoryTotalGB = empty.memoryTotalGB
}

function applyHistory(series: ReturnType<typeof mapStatsHistorySamples>) {
  history.labels = series.labels
  history.cpu = series.cpu
  history.memoryGB = series.memoryGB
  history.memoryTotalGB = series.memoryTotalGB
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

const latestCpu = computed(() => {
  if (history.cpu.length) return history.cpu[history.cpu.length - 1]
  return device.value?.resources?.cpuLoadPercent ?? null
})
const latestMemoryGB = computed(() => {
  if (history.memoryGB.length) return history.memoryGB[history.memoryGB.length - 1]
  const used = device.value?.resources?.memoryUsedMB
  return used != null ? used / 1024 : null
})
const memoryTotalGB = computed(() => {
  if (history.memoryTotalGB != null) return history.memoryTotalGB
  const total = device.value?.resources?.memoryTotalMB
  return total != null ? total / 1024 : null
})

async function refreshAbout(row: HomeDeviceHealthSnapshot | null = device.value) {
  if (!row || !canFetchDeviceWorkloads(row)) {
    deviceAbout.value = null
    aboutReady.value = true
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
  if (hostId.value === host) aboutReady.value = true
}

async function refreshCapabilities(row: HomeDeviceHealthSnapshot | null = device.value) {
  if (!row || !canFetchDeviceWorkloads(row)) {
    deviceCaps.value = null
    hostGPUs.value = []
    return
  }
  const host = row.hostId
  try {
    const { data } = await api.get(deviceCapabilitiesPath(row))
    if (hostId.value !== host) return
    deviceCaps.value = parseSystemCapabilities(data)
  } catch {
    if (hostId.value !== host) return
    deviceCaps.value = null
  }
  try {
    const { data } = await api.get<HostGPUDevice[]>(deviceGpuDevicesPath(row))
    if (hostId.value !== host) return
    hostGPUs.value = Array.isArray(data) ? data : []
  } catch {
    if (hostId.value !== host) return
    hostGPUs.value = []
  }
}

function clearHostTransientState() {
  stopConfirm.value = null
  for (const id of Object.keys(restartLoading)) {
    delete restartLoading[id]
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

async function refreshDevice(row: HomeDeviceHealthSnapshot | null = device.value) {
  if (!row) return
  await workloads.fetchFor(row)
  await refreshAbout(row)
  await refreshCapabilities(row)
  await refreshHistory(row)
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
  aboutReady.value = false
  deviceCaps.value = null
  hostGPUs.value = []
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
  <div class="device-detail">
    <button class="back-link" type="button" @click="router.push('/devices')">
      ← {{ DEVICE_LABEL }}s
    </button>

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
      <div class="detail-header">
        <div>
          <h1>{{ title }}</h1>
          <p class="detail-meta">
            <span v-if="device.role === 'self'" class="device-chip self">This {{ DEVICE_LABEL }}</span>
            <span v-else class="device-chip">{{ DEVICE_LABEL }}</span>
            <span v-if="platformLabel">{{ platformLabel }}</span>
          </p>
          <p class="detail-workload">{{ workloadLine }}</p>
          <p v-if="resourcesLine" class="detail-res">{{ resourcesLine }}</p>
        </div>
        <div class="detail-actions">
          <AppButton
            v-if="canFetchDeviceWorkloads(device)"
            variant="primary"
            icon="plus"
            @click="showCreate = true"
          >
            Create VM
          </AppButton>
          <span class="status-pill" :class="reachPill">
            {{ reachLabel }}
          </span>
        </div>
      </div>

      <div v-if="shouldFetchDeviceStatsHistory(device)" class="stat-grid">
        <div class="dash-stat" style="border-left: 3px solid var(--accent)">
          <div class="dash-stat-spark" v-if="history.cpu.length > 1">
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
        <div class="dash-stat" style="border-left: 3px solid var(--green)">
          <div class="dash-stat-spark" v-if="history.memoryGB.length > 1">
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
      </div>

      <div v-if="canFetchDeviceWorkloads(device) && aboutReady" class="gpu-card">
        <div class="gpu-card-title">About</div>
        <dl v-if="deviceAbout" class="about-rows">
          <div>
            <dt>Device version</dt>
            <dd>{{ deviceAbout.version }}</dd>
          </div>
          <div>
            <dt>Platform</dt>
            <dd>{{ deviceAbout.platform }} · {{ deviceAbout.hostArch }}</dd>
          </div>
          <div>
            <dt>Accelerator</dt>
            <dd>{{ deviceAbout.accelerator }}</dd>
          </div>
          <div>
            <dt>Uptime</dt>
            <dd>{{ deviceAbout.processUptimeSeconds }}s</dd>
          </div>
        </dl>
        <p v-else class="gpu-card-status">Could not load this {{ DEVICE_LABEL.toLowerCase() }} version.</p>
      </div>

      <div v-if="deviceCaps" class="gpu-card">
        <div class="gpu-card-title">GPU passthrough</div>
        <p class="gpu-card-status">{{ gpuReady ? 'This Device reports IOMMU, vfio-pci, and KVM.' : 'Not available on this Device.' }}</p>
        <UnsupportedHint :text="gpuExplanation" />
        <p v-if="gpuReady && hostGPUs.length === 1" class="gpu-warning" role="alert">{{ GPU_SINGLE_DISPLAY_WARNING }}</p>
        <ul v-if="hostGPUs.length" class="gpu-list">
          <li v-for="gpu in hostGPUs" :key="gpu.pciAddress">
            <span class="gpu-name">{{ gpu.name }}</span>
            <span class="gpu-meta">{{ gpu.pciAddress }} · IOMMU {{ gpu.iommuGroup }}</span>
            <span class="gpu-meta">Group mates: {{ gpuGroupMatesLabel(gpu.pciAddress, gpu.groupAddresses) }}</span>
            <span v-if="gpu.claimedByVMName" class="gpu-busy">Attached to {{ gpu.claimedByVMName }}</span>
            <span v-else-if="gpu.inUseByHost" class="gpu-busy">{{ gpuHostOccupancyLabel(true) }}</span>
          </li>
        </ul>
        <p v-if="gpuReady" class="gpu-card-status">Guest Ollama path: {{ GUEST_OLLAMA_PATH }}</p>
      </div>

      <p v-if="!canFetchDeviceWorkloads(device)" class="unreachable-copy">
        {{ reachHint }}
        Workload counts are not shown.
      </p>

      <template v-else>
        <p v-if="listError" class="list-error">{{ listError }}</p>

        <EmptyState
          v-if="showEmptyWorkloads"
          icon="monitor"
          title="No workloads on this Device"
        />

        <p v-else-if="showLoadingWorkloads" class="list-loading">Loading workloads...</p>

        <DataTable
          v-else-if="listSettled || vms.length > 0"
          :columns="[
            { key: 'name', label: 'Workload' },
            { key: 'resources', label: 'Resources' },
            { key: 'status', label: 'Status' },
            { key: 'actions', label: '' },
          ]"
        >
          <tr v-for="vm in vms" :key="vm.id" class="vm-row" @click="openWorkload(vm)">
            <td>
              <div class="vm-name">{{ vm.name }}</div>
              <div v-if="vm.description" class="vm-desc">{{ vm.description }}</div>
            </td>
            <td class="vm-res">
              {{ vm.cpuCount }} CPU ·
              {{ vm.memoryMB >= 1024
                ? (vm.memoryMB / 1024).toFixed(vm.memoryMB % 1024 === 0 ? 0 : 1) + ' GB'
                : vm.memoryMB + ' MB' }}
            </td>
            <td>
              <span
                class="status-pill"
                :class="healthPillClass(vmHealth(vm))"
                :title="vm.status?.healthError || undefined"
              >{{ healthLabel(vmHealth(vm)) }}</span>
            </td>
            <td>
              <div class="vm-actions" @click.stop>
                <AppButton
                  v-if="vm.state === 'stopped' || vm.state === 'error'"
                  variant="primary"
                  size="sm"
                  :disabled="workloads.isActing(hostId, vm.id)"
                  @click="doStart(vm.id)"
                >
                  {{ workloads.isActing(hostId, vm.id) ? 'Starting...' : 'Start' }}
                </AppButton>
                <template v-else-if="vm.state === 'running'">
                  <AppButton
                    variant="warning"
                    size="sm"
                    :disabled="restartLoading[vm.id] || workloads.isActing(hostId, vm.id)"
                    @click="doRestart(vm.id)"
                  >
                    {{ restartLoading[vm.id] ? 'Restarting...' : 'Restart' }}
                  </AppButton>
                  <StopButtonGroup
                    size="sm"
                    :loading="workloads.isActing(hostId, vm.id)"
                    @stop="requestStop(vm.id, $event)"
                  />
                </template>
              </div>
            </td>
          </tr>
        </DataTable>
      </template>
    </template>

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
.device-detail {
  min-width: 0;
  max-width: 100%;
}
.back-link {
  background: none;
  border: 0;
  padding: 0;
  margin: 0 0 16px;
  color: var(--text-dim);
  font-size: 13px;
  cursor: pointer;
}
.back-link:hover { color: var(--text-primary); }
.detail-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 12px;
  margin-bottom: 20px;
  min-width: 0;
}
.detail-actions {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 10px;
}
.detail-header h1 {
  margin: 0;
  font-size: 28px;
  font-weight: 700;
  letter-spacing: -0.03em;
}
.detail-meta {
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
.detail-workload,
.detail-res {
  margin: 8px 0 0;
  font-size: 13px;
  color: var(--text-secondary);
}
.detail-res {
  font-variant-numeric: tabular-nums;
  font-size: 12px;
}
.stat-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(min(240px, 100%), 1fr));
  gap: 16px;
  margin-bottom: 20px;
  min-width: 0;
}
.dash-stat {
  position: relative;
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  overflow: hidden;
  min-width: 0;
  min-height: 120px;
}
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
  padding: 20px;
}
.dash-stat-top {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 8px;
  margin-bottom: 12px;
}
.dash-stat-number {
  font-size: 32px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  letter-spacing: -0.03em;
  line-height: 1;
}
.dash-stat-number small {
  font-size: 16px;
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
.unreachable-copy,
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
  font-size: 28px;
}
.vm-row { cursor: pointer; }
.vm-row:hover { background: var(--bg-hover); }
.vm-name { font-weight: 500; }
.vm-desc {
  font-size: 12px;
  color: var(--text-dim);
  margin-top: 2px;
}
.vm-res {
  font-size: 12px;
  color: var(--text-secondary);
}
.vm-actions {
  display: flex;
  gap: 6px;
  justify-content: flex-end;
}
.about-rows {
  margin: 8px 0 0;
  display: grid;
  gap: 6px;
  min-width: 0;
}
.about-rows > div {
  display: flex;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 12px;
  font-size: 13px;
  min-width: 0;
}
.about-rows dt {
  color: var(--text-secondary);
}
.about-rows dd {
  margin: 0;
  font-variant-numeric: tabular-nums;
  overflow-wrap: anywhere;
}
.gpu-card {
  margin: 0 0 20px;
  padding: 12px 14px;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--bg-elevated, var(--bg-hover));
  min-width: 0;
  overflow-wrap: anywhere;
}
.gpu-card-title {
  font-size: 13px;
  font-weight: 600;
}
.gpu-card-status {
  margin: 4px 0 0;
  font-size: 13px;
  color: var(--text-secondary);
}
.gpu-list {
  list-style: none;
  margin: 10px 0 0;
  padding: 0;
}
.gpu-list li {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  font-size: 12px;
  padding: 4px 0;
}
.gpu-name { font-weight: 500; }
.gpu-meta { font-family: var(--font-mono); color: var(--text-dim); }
.gpu-busy { color: var(--red); }
.gpu-warning {
  margin: 8px 0 0;
  font-size: 13px;
  font-weight: 700;
  color: var(--red);
}

@media (max-width: 1024px) {
  .detail-header h1,
  .missing h1 { font-size: 24px; }
}

@media (max-width: 768px) {
  .detail-header h1,
  .missing h1 { font-size: 22px; }
  .stat-grid { grid-template-columns: 1fr; }
}
</style>
