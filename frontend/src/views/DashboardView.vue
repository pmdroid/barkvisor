<script setup lang="ts">
import { onMounted, onUnmounted, ref, reactive, computed } from 'vue'
import { useRouter } from 'vue-router'
import { useVMStore } from '../stores/vms'
import AppButton from '../components/ui/AppButton.vue'
import DataTable from '../components/ui/DataTable.vue'
import api from '../api/client'
import type { SystemStats, SystemStatsSample, Disk, StorageSummary } from '../api/types'
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
const stats = ref<SystemStats | null>(null)
const disks = ref<Disk[]>([])
const storageSummary = ref<StorageSummary | null>(null)
const history = reactive<{ timestamps: string[]; cpu: number[]; memory: number[] }>({
  timestamps: [],
  cpu: [],
  memory: [],
})

const runningVMs = computed(() => store.vms.filter(v => v.state === 'running').length)

const recentVMs = computed(() =>
  [...store.vms].sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime()).slice(0, 5)
)
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
  try {
    const [diskRes, summaryRes] = await Promise.all([
      api.get('/disks'),
      api.get('/disks/summary'),
    ])
    disks.value = diskRes.data
    storageSummary.value = summaryRes.data
  } catch { /* ignore */ }
}

let pollTimer: number
onMounted(() => {
  store.fetchAll()
  fetchHistory()
  fetchStats()
  fetchStorage()
  pollTimer = window.setInterval(fetchStats, 5000)
})
onUnmounted(() => clearInterval(pollTimer))

function stateLabel(state: string) {
  return state.charAt(0).toUpperCase() + state.slice(1)
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
        <p class="welcome-sub">{{ runningVMs }} of {{ store.vms.length }} VMs running</p>
      </div>
      <AppButton variant="primary" icon="plus" @click="router.push('/vms?create=1')">Create VM</AppButton>
    </div>

    <!-- Host Stats -->
    <div class="stat-grid" v-if="stats">
      <div class="dash-stat" style="border-left: 3px solid var(--accent)">
        <div class="dash-stat-spark" v-if="history.cpu.length > 1">
          <Line :data="cpuSparkData" :options="cpuSparkOpts" />
        </div>
        <div class="dash-stat-content">
          <div class="dash-stat-top">
            <span class="dash-stat-number">{{ stats.hostCpuPercent.toFixed(0) }}%</span>
            <span class="dash-stat-trend" :class="stats.hostCpuPercent > 80 ? 'warn' : 'up'">host</span>
          </div>
          <div class="dash-stat-label">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="16" height="16" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M15 2v2"/><path d="M15 20v2"/><path d="M2 15h2"/><path d="M2 9h2"/><path d="M20 15h2"/><path d="M20 9h2"/><path d="M9 2v2"/><path d="M9 20v2"/></svg>
            CPU
          </div>
        </div>
      </div>

      <div class="dash-stat" style="border-left: 3px solid var(--green)">
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
          </div>
        </div>
      </div>

      <div class="dash-stat" style="border-left: 3px solid var(--blue)">
        <div class="dash-stat-content">
          <div class="dash-stat-top">
            <span class="dash-stat-number">{{ totalDiskGB }} <small>GB</small></span>
            <span class="dash-stat-trend up">{{ disks.length }} disks</span>
          </div>
          <div class="dash-stat-label">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><ellipse cx="12" cy="5" rx="9" ry="3"/><path d="M3 5v14c0 1.66 4.03 3 9 3s9-1.34 9-3V5"/><path d="M3 12c0 1.66 4.03 3 9 3s9-1.34 9-3"/></svg>
            Storage
          </div>
          <div class="dash-stat-bar" v-if="storageSummary"><div class="dash-stat-bar-fill" :style="{ width: Math.min(storageSummary.totalActualBytes / storageSummary.volumeTotalBytes * 100, 100) + '%', background: 'var(--blue)' }" /></div>
        </div>
      </div>
    </div>

    <!-- Recent VMs -->
    <div class="section" v-if="recentVMs.length > 0">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px">
        <h2>Recent Machines</h2>
        <AppButton size="sm" @click="router.push('/vms')">View all</AppButton>
      </div>
      <DataTable :columns="[
        { key: 'name', label: 'Name' },
        { key: 'status', label: 'Status' },
        { key: 'type', label: 'Type' },
        { key: 'cpu', label: 'CPU' },
        { key: 'memory', label: 'Memory' },
        { key: 'updated', label: 'Updated' },
      ]">
        <tr v-for="vm in recentVMs" :key="vm.id" @click="router.push(`/vms/${vm.id}`)" style="cursor:pointer">
          <td style="font-weight:600">{{ vm.name }}</td>
          <td><span class="status-pill" :class="vm.state">{{ stateLabel(vm.state) }}</span></td>
          <td><span class="badge badge-gray">{{ vm.vmType.startsWith('windows') ? 'Windows' : 'Linux' }}</span></td>
          <td style="font-variant-numeric:tabular-nums">{{ vm.cpuCount }} cores</td>
          <td style="font-variant-numeric:tabular-nums">{{ vm.memoryMB >= 1024 ? (vm.memoryMB / 1024).toFixed(1) + ' GB' : vm.memoryMB + ' MB' }}</td>
          <td style="color:var(--text-dim);font-size:12px">{{ new Date(vm.updatedAt).toLocaleDateString() }}</td>
        </tr>
      </DataTable>
    </div>

  </div>
</template>

<style scoped>
.dashboard {
  max-width: 100%;
}

/* Welcome */
.welcome {
  display: flex;
  align-items: center;
  justify-content: space-between;
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

/* Stat Cards */
.stat-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 16px;
  margin-bottom: 40px;
}
.dash-stat {
  position: relative;
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  overflow: hidden;
}
.dash-stat-spark {
  position: absolute;
  inset: 0;
  pointer-events: none;
  opacity: 0.7;
}
.dash-stat-spark canvas {
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
