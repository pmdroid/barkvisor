<script setup lang="ts">
import { onMounted, onUnmounted, ref, reactive, computed } from 'vue'
import { useRouter } from 'vue-router'
import { useVMStore } from '../stores/vms'
import { useDiskStore } from '../stores/disks'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import AppButton from '../components/ui/AppButton.vue'
import DataTable from '../components/ui/DataTable.vue'
import DeviceCard from '../components/DeviceCard.vue'
import WorkloadDeviceChip from '../components/home/WorkloadDeviceChip.vue'
import type { HomeWorkloadRow } from '../stores/deviceWorkloads'
import api from '../api/client'
import type { SystemStats, SystemStatsSample, WorkloadHealth, WorkloadHealthSummary } from '../api/types'
import {
  DASHBOARD_WIDGET_LABELS,
  DASHBOARD_WIDGETS_STORAGE_KEY,
  DEFAULT_WIDGETS,
  isThisDeviceWidget,
  isWidgetVisible,
  parseDashboardLayout,
  resetDashboardLayout,
  toggleWidget,
  type DashboardWidgetId,
} from '../utils/dashboardWidgets'
import { formatTemperatureC } from '../utils/format'
import { scopeRows } from '../utils/deviceScope'
import { hasKnownHealthCounts, homeWorkloadsRunningLine, resolveHealthCounts } from '../utils/homeDeviceHealth'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'
import { healthLabel, healthPillClass, vmHealth } from '../utils/workloadHealth'
import { listBackendBadge, vmBackend } from '../utils/workloadBackend'
import { openWorkloadRow, workloadRowKey } from '../utils/workloadDetail'
import { storeToRefs } from 'pinia'
import { Line } from 'vue-chartjs'
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Filler,
} from 'chart.js'

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Filler)

const MAX_HISTORY = 60

const router = useRouter()
const store = useVMStore()
const diskStore = useDiskStore()
const devices = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const homeWorkloads = useDeviceWorkloadsStore()
const { disks, summary: storageSummary } = storeToRefs(diskStore)
const stats = ref<SystemStats | null>(null)
const healthSummary = ref<WorkloadHealthSummary | null>(null)
const customizeOpen = ref(false)
const history = reactive<{ timestamps: string[]; cpu: number[]; memory: number[] }>({
  timestamps: [],
  cpu: [],
  memory: [],
})

function loadLayout(): DashboardWidgetId[] {
  try {
    return parseDashboardLayout(localStorage.getItem(DASHBOARD_WIDGETS_STORAGE_KEY))
  } catch {
    return resetDashboardLayout()
  }
}

const layout = ref<DashboardWidgetId[]>(loadLayout())

function persistLayout(next: DashboardWidgetId[]) {
  layout.value = next
  try {
    if (next.length === DEFAULT_WIDGETS.length && DEFAULT_WIDGETS.every((id, i) => id === next[i])) {
      localStorage.removeItem(DASHBOARD_WIDGETS_STORAGE_KEY)
    } else {
      localStorage.setItem(DASHBOARD_WIDGETS_STORAGE_KEY, JSON.stringify(next))
    }
  } catch {
  }
}

function widgetOn(id: DashboardWidgetId): boolean {
  return isWidgetVisible(layout.value, id)
}

function onToggleWidget(id: DashboardWidgetId) {
  persistLayout(toggleWidget(layout.value, id))
}

function onResetWidgets() {
  persistLayout(resetDashboardLayout())
}

const scopedDevices = computed(() => scopeRows(devices.devices, deviceScope.selectedHostId))
const showThisDeviceStats = computed(() => {
  if (deviceScope.isAll) return true
  const selfId = devices.selfDevice?.hostId
  return Boolean(selfId && deviceScope.selectedHostId === selfId)
})
const anyThisDeviceWidget = computed(() =>
  showThisDeviceStats.value && (['cpu', 'memory', 'storage', 'temperature'] as const).some((id) => widgetOn(id)),
)
const thisDeviceScope = computed(() => `This ${DEVICE_LABEL}`)
const homeWidgetScope = computed(() => {
  if (deviceScope.isAll) return HOME_LABEL
  const row = scopedDevices.value[0]
  return row ? devices.deviceLabel(row) : DEVICE_LABEL
})

function widgetScopeLabel(id: DashboardWidgetId): string {
  if (isThisDeviceWidget(id)) return thisDeviceScope.value
  return homeWidgetScope.value
}

const runningVMs = computed(() => store.vms.filter(v => v.state === 'running').length)

const healthStrip = computed(() => {
  const preferred = deviceScope.isAll
    ? devices.totals?.healthCounts
    : scopedDevices.value[0]?.healthCounts
  const fallback = deviceScope.isAll ? healthSummary.value?.counts : undefined
  const counts = resolveHealthCounts(preferred, fallback)
  return (['running', 'starting', 'degraded', 'failed', 'stopped'] as WorkloadHealth[])
    .map((key) => ({ key, count: counts[key] ?? 0, label: healthLabel(key) }))
})

const failedCount = computed(() => {
  if (!deviceScope.isAll) return scopedDevices.value[0]?.healthCounts?.failed ?? 0
  const counts = devices.totals?.healthCounts
  if (hasKnownHealthCounts(counts)) return counts.failed ?? 0
  return healthSummary.value?.counts?.failed ?? 0
})

const homeRunningCount = computed(() => {
  if (!deviceScope.isAll) return scopedDevices.value[0]?.healthCounts?.running ?? 0
  const counts = devices.totals?.healthCounts
  if (hasKnownHealthCounts(counts)) return counts.running ?? 0
  return runningVMs.value
})

const homeWorkloadsLine = computed(() => {
  if (!deviceScope.isAll) {
    const row = scopedDevices.value[0]
    if (row?.workloadCount == null) return null
    return homeWorkloadsRunningLine({ workloadCount: row.workloadCount }, homeRunningCount.value)
  }
  return homeWorkloadsRunningLine(devices.totals, homeRunningCount.value)
})

const homeRows = computed(() =>
  scopeRows(homeWorkloads.homeRows(devices.devices), deviceScope.selectedHostId),
)

const recentVMs = computed(() =>
  [...homeRows.value]
    .sort((a, b) => new Date(b.vm.updatedAt).getTime() - new Date(a.vm.updatedAt).getTime())
    .slice(0, 5),
)

function openRow(row: HomeWorkloadRow) {
  openWorkloadRow((path) => { router.push(path) }, row)
}

function emuBadge(vm: (typeof store.vms)[0]) {
  return listBackendBadge(vmBackend(vm))
}
const totalDiskGB = computed(() => {
  if (storageSummary.value) return (storageSummary.value.totalActualBytes / 1073741824).toFixed(1)
  const bytes = disks.value.reduce((sum, d) => sum + d.sizeBytes, 0)
  return (bytes / 1073741824).toFixed(1)
})

async function fetchStats() {
  try {
    const { data } = await api.get('/system/stats')
    stats.value = data
    const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
    history.timestamps.push(now)
    history.cpu.push(data.hostCpuPercent)
    history.memory.push(data.hostMemoryUsedMB / 1024)
    if (history.timestamps.length > MAX_HISTORY) {
      history.timestamps.shift()
      history.cpu.shift()
      history.memory.shift()
    }
  } catch { /* ignore */ }
}

async function fetchHistory() {
  try {
    const { data } = await api.get<SystemStatsSample[]>('/system/stats/history?minutes=30')
    for (const s of data) {
      const t = new Date(s.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
      history.timestamps.push(t)
      history.cpu.push(s.hostCpuPercent)
      history.memory.push(s.hostMemoryUsedMB / 1024)
    }
    if (history.timestamps.length > MAX_HISTORY) {
      const excess = history.timestamps.length - MAX_HISTORY
      history.timestamps.splice(0, excess)
      history.cpu.splice(0, excess)
      history.memory.splice(0, excess)
    }
  } catch { /* ignore - will build up from polling */ }
}

async function fetchStorage() {
  await Promise.all([diskStore.fetchAll(), diskStore.fetchSummary()])
}

async function fetchHealthSummary() {
  try {
    const { data } = await api.get<WorkloadHealthSummary>('/workloads/health-summary')
    healthSummary.value = data
  } catch { /* ignore */ }
}

let pollTimer: number
async function refreshHomeWorkloads() {
  await devices.fetchHealth().catch(() => {})
  const list = devices.devices
  if (list.length === 0) {
    await store.fetchAll()
    return
  }
  await homeWorkloads.fetchHomeAll(list)
}

onMounted(() => {
  void refreshHomeWorkloads()
  fetchHistory()
  fetchStats()
  fetchStorage()
  fetchHealthSummary()
  pollTimer = window.setInterval(() => {
    fetchStats()
    fetchHealthSummary()
    void refreshHomeWorkloads()
  }, 5000)
})
onUnmounted(() => clearInterval(pollTimer))

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
  makeSparkOpts(stats.value ? Math.ceil(stats.value.hostMemoryTotalMB / 1024) : undefined)
)

const cpuSparkData = computed(() => ({
  labels: history.timestamps,
  datasets: [{
    data: history.cpu,
    borderColor: 'rgba(0,144,248,0.5)',
    backgroundColor: 'rgba(0,144,248,0.06)',
    fill: true,
  }],
}))

const memSparkData = computed(() => ({
  labels: history.timestamps,
  datasets: [{
    data: history.memory,
    borderColor: 'rgba(52,211,153,0.5)',
    backgroundColor: 'rgba(52,211,153,0.06)',
    fill: true,
  }],
}))
</script>

<template>
  <div class="dashboard">

    <!-- Welcome -->
    <div class="welcome">
      <div>
        <h1>Dashboard</h1>
        <p class="welcome-sub">
          <template v-if="!deviceScope.isAll && scopedDevices[0]">
            {{ devices.deviceLabel(scopedDevices[0]) }}
            <template v-if="homeWorkloadsLine">
              · {{ homeWorkloadsLine }}
            </template>
          </template>
          <template v-else-if="devices.totals">
            {{ devices.totals.devices }} {{ devices.totals.devices === 1 ? DEVICE_LABEL : DEVICE_LABEL + 's' }}
            <template v-if="homeWorkloadsLine">
              · {{ homeWorkloadsLine }}
            </template>
            <span v-if="devices.totals.unreachable > 0">
              · {{ devices.totals.unreachable }} unreachable
            </span>
          </template>
          <template v-else>
            {{ runningVMs }} of {{ store.vms.length }} VMs running
          </template>
          <span v-if="failedCount > 0"> · {{ failedCount }} failed</span>
        </p>
      </div>
      <div class="welcome-actions">
        <AppButton size="sm" @click="customizeOpen = !customizeOpen">Customize</AppButton>
        <AppButton variant="primary" icon="plus" @click="router.push('/vms?create=1')">Create VM</AppButton>
      </div>
    </div>

    <div v-if="customizeOpen" class="widget-panel">
      <div class="widget-panel-head">
        <span>Widgets</span>
        <AppButton size="sm" @click="onResetWidgets">Reset</AppButton>
      </div>
      <div class="widget-checks">
        <label v-for="id in DEFAULT_WIDGETS" :key="id" class="widget-check">
          <input
            type="checkbox"
            :checked="widgetOn(id)"
            @change="onToggleWidget(id)"
          >
          <span>{{ DASHBOARD_WIDGET_LABELS[id] }}</span>
          <span class="widget-scope">{{ widgetScopeLabel(id) }}</span>
        </label>
      </div>
    </div>

    <div v-if="widgetOn('devices') && scopedDevices.length" class="section device-home">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
        <h2>
          {{ DEVICE_LABEL }}s
          <span class="widget-scope">{{ homeWidgetScope }}</span>
        </h2>
        <AppButton size="sm" @click="router.push('/devices')">View all</AppButton>
      </div>
      <div class="device-grid">
        <DeviceCard v-for="row in scopedDevices" :key="row.hostId" :device="row" />
      </div>
    </div>

    <div v-if="widgetOn('health') && (healthSummary || devices.totals)" class="health-strip">
      <span class="widget-scope health-scope">{{ homeWidgetScope }}</span>
      <div v-for="row in healthStrip" :key="row.key" class="health-chip" :class="row.key">
        <span class="health-chip-count">{{ row.count }}</span>
        <span class="health-chip-label">{{ row.label }}</span>
      </div>
    </div>

    <!-- Host Stats (this Device only; hidden when another Device is scoped) -->
    <div class="stat-grid" v-if="stats && anyThisDeviceWidget">
      <div v-if="widgetOn('cpu')" class="dash-stat" style="border-left: 3px solid var(--accent)">
        <div class="dash-stat-spark" v-if="history.cpu.length > 1">
          <Line :data="cpuSparkData" :options="cpuSparkOpts" />
        </div>
        <div class="dash-stat-content">
          <div class="dash-stat-top">
            <span class="dash-stat-number">{{ stats.hostCpuPercent.toFixed(0) }}%</span>
            <span class="dash-stat-trend" :class="stats.hostCpuPercent > 80 ? 'warn' : 'up'">{{ thisDeviceScope }}</span>
          </div>
          <div class="dash-stat-label">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M15 2v2"/><path d="M15 20v2"/><path d="M2 15h2"/><path d="M2 9h2"/><path d="M20 15h2"/><path d="M20 9h2"/><path d="M9 2v2"/><path d="M9 20v2"/></svg>
            CPU
          </div>
        </div>
      </div>

      <div v-if="widgetOn('memory')" class="dash-stat" style="border-left: 3px solid var(--green)">
        <div class="dash-stat-spark" v-if="history.memory.length > 1">
          <Line :data="memSparkData" :options="memSparkOpts" />
        </div>
        <div class="dash-stat-content">
          <div class="dash-stat-top">
            <span class="dash-stat-number">{{ (stats.hostMemoryUsedMB / 1024).toFixed(1) }} <small>GB</small></span>
            <span class="dash-stat-trend up">/ {{ (stats.hostMemoryTotalMB / 1024).toFixed(0) }} GB</span>
          </div>
          <div class="dash-stat-label">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 19v-8a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v8"/><path d="M6 19h12"/><path d="M10 5h4v4h-4z"/></svg>
            Memory
            <span class="widget-scope">{{ thisDeviceScope }}</span>
          </div>
        </div>
      </div>

      <div v-if="widgetOn('storage')" class="dash-stat" style="border-left: 3px solid var(--blue)">
        <div class="dash-stat-content">
          <div class="dash-stat-top">
            <span class="dash-stat-number">{{ totalDiskGB }} <small>GB</small></span>
            <span class="dash-stat-trend up">{{ disks.length }} disks</span>
          </div>
          <div class="dash-stat-label">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14c0 1.66 4.03 3 9 3s9-1.34 9-3V5"/><path d="M3 12c0 1.66 4.03 3 9 3s9-1.34 9-3"/></svg>
            Storage
            <span class="widget-scope">{{ thisDeviceScope }}</span>
          </div>
          <div class="dash-stat-bar" v-if="storageSummary"><div class="dash-stat-bar-fill" :style="{ width: Math.min(storageSummary.totalActualBytes / storageSummary.volumeTotalBytes * 100, 100) + '%', background: 'var(--blue)' }" /></div>
        </div>
      </div>

      <div v-if="widgetOn('temperature')" class="dash-stat" style="border-left: 3px solid var(--amber)">
        <div class="dash-stat-content">
          <div class="dash-stat-top">
            <span class="dash-stat-number">{{ formatTemperatureC(stats.metrics?.temperatureC) ?? '—' }}</span>
            <span class="dash-stat-trend" :class="stats.metrics?.temperatureC == null ? '' : 'up'">
              {{ stats.metrics?.temperatureC == null ? 'unavailable' : thisDeviceScope }}
            </span>
          </div>
          <div class="dash-stat-label">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 14.76V3.5a2.5 2.5 0 0 0-5 0v11.26a4.5 4.5 0 1 0 5 0z"/></svg>
            Temperature
            <span class="widget-scope">{{ thisDeviceScope }}</span>
          </div>
        </div>
      </div>
    </div>

    <!-- Recent VMs -->
    <div class="section" v-if="widgetOn('recent') && recentVMs.length > 0">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px">
        <h2>
          Recent Machines
          <span class="widget-scope">{{ homeWidgetScope }}</span>
        </h2>
        <AppButton size="sm" @click="router.push('/vms')">View all</AppButton>
      </div>
      <DataTable :columns="[
        { key: 'name', label: 'Name' },
        { key: 'device', label: 'Device' },
        { key: 'status', label: 'Status' },
        { key: 'type', label: 'Type' },
        { key: 'cpu', label: 'CPU' },
        { key: 'memory', label: 'Memory' },
        { key: 'updated', label: 'Updated' },
      ]">
        <tr v-for="row in recentVMs" :key="workloadRowKey(row)" @click="openRow(row)" style="cursor:pointer">
          <td>
            <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap">
              <span style="font-weight:600">{{ row.vm.name }}</span>
              <span
                v-if="emuBadge(row.vm)"
                class="badge badge-amber"
                :title="emuBadge(row.vm)!.title"
              >{{ emuBadge(row.vm)!.label }}</span>
            </div>
          </td>
          <td>
            <WorkloadDeviceChip
              :label="row.label"
              :self="row.role === 'self'"
              :reachable="row.reachable"
            />
          </td>
          <td>
            <span
              class="status-pill"
              :class="healthPillClass(vmHealth(row.vm))"
              :title="row.vm.status?.healthError || undefined"
            >{{ healthLabel(vmHealth(row.vm)) }}</span>
          </td>
          <td><span class="badge badge-gray">{{ row.vm.vmType.startsWith('windows') ? 'Windows' : 'Linux' }}</span></td>
          <td style="font-variant-numeric:tabular-nums">{{ row.vm.cpuCount }} cores</td>
          <td style="font-variant-numeric:tabular-nums">{{ row.vm.memoryMB >= 1024 ? (row.vm.memoryMB / 1024).toFixed(1) + ' GB' : row.vm.memoryMB + ' MB' }}</td>
          <td style="color:var(--text-dim);font-size:12px">{{ new Date(row.vm.updatedAt).toLocaleDateString() }}</td>
        </tr>
      </DataTable>
    </div>

  </div>
</template>

<style scoped>
.dashboard {
  min-width: 0;
  max-width: 100%;
}

/* Welcome */
.welcome {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: 12px;
  margin-bottom: 32px;
}
.welcome h1 {
  font-size: 28px;
  font-weight: 700;
  letter-spacing: -0.03em;
}
.welcome-sub {
  color: var(--text-dim);
  font-size: 13px;
  margin-top: 4px;
}
.welcome-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}
.widget-panel {
  background: var(--bg-card);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  padding: 16px;
  margin: -16px 0 28px;
}
.widget-panel-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 12px;
  font-size: 13px;
  font-weight: 600;
}
.widget-checks {
  display: flex;
  flex-wrap: wrap;
  gap: 10px 18px;
}
.widget-check {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  color: var(--text-secondary);
  cursor: pointer;
}
.widget-check input[type="checkbox"] {
  width: 14px;
  height: 14px;
  padding: 0;
  margin: 0;
  flex-shrink: 0;
  accent-color: var(--accent);
  box-shadow: none;
}
.widget-scope {
  font-size: 10px;
  font-weight: 600;
  letter-spacing: 0.02em;
  color: var(--text-dim);
}
h2 .widget-scope {
  margin-left: 8px;
  vertical-align: middle;
}
.health-scope {
  align-self: center;
  margin-right: 4px;
}
.health-strip {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin: -16px 0 24px;
}
.health-chip {
  display: inline-flex;
  align-items: baseline;
  gap: 6px;
  padding: 8px 12px;
  border: 1px solid var(--border-glass);
  background: var(--bg-card);
  border-radius: var(--radius);
  color: var(--text-secondary);
}
.health-chip-count {
  font-size: 16px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.health-chip-label {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

/* Stat Cards */
.stat-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 16px;
  margin-bottom: 40px;
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
  display: flex;
  align-items: center;
  gap: 4px;
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
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
}
.dash-stat-bar {
  height: 4px;
  background: rgba(255,255,255,0.06);
  border-radius: 2px;
  overflow: hidden;
  margin-top: 12px;
}
.dash-stat-bar-fill {
  height: 100%;
  transition: width 0.5s ease;
}

/* Sections */
.section {
  margin-bottom: 36px;
}
.section h2 {
  font-size: 18px;
  font-weight: 700;
  letter-spacing: -0.02em;
}
.device-home {
  margin-bottom: 28px;
}
.device-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(280px, 100%), 1fr));
  gap: 16px;
}
.device-grid > * {
  min-width: 0;
}

@media (max-width: 1024px) {
  .stat-grid { grid-template-columns: repeat(2, 1fr); }
}

@media (max-width: 768px) {
  .welcome { flex-direction: column; align-items: flex-start; gap: 12px; margin-bottom: 24px; }
  .welcome h1 { font-size: 22px; }
  .stat-grid { grid-template-columns: 1fr; gap: 12px; margin-bottom: 28px; }
  .section { margin-bottom: 28px; }
  table { min-width: 500px; }
}
</style>
