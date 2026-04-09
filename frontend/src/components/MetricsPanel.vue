<script setup lang="ts">
import { computed, onMounted, onUnmounted } from 'vue'
import { Line } from 'vue-chartjs'
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Title,
  Tooltip,
  Filler,
} from 'chart.js'
import { useMetricsStore } from '../stores/metrics'

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Filler)

const props = defineProps<{ vmId: string }>()
const store = useMetricsStore()

onMounted(() => store.connect(props.vmId))
onUnmounted(() => store.disconnect())

const labels = computed(() =>
  store.samples.map(s => new Date(s.timestamp).toLocaleTimeString())
)

const chartOpts = {
  responsive: true,
  maintainAspectRatio: false,
  animation: false as const,
  scales: {
    x: {
      display: false,
      grid: { display: false },
    },
    y: {
      beginAtZero: true,
      grid: { color: getComputedStyle(document.documentElement).getPropertyValue('--chart-grid').trim() },
      ticks: { color: '#666', font: { size: 10 } },
      border: { display: false },
    },
  },
  plugins: {
    tooltip: {
      backgroundColor: getComputedStyle(document.documentElement).getPropertyValue('--chart-tooltip-bg').trim(),
      borderColor: getComputedStyle(document.documentElement).getPropertyValue('--chart-tooltip-border').trim(),
      borderWidth: 1,
      titleFont: { size: 11 },
      bodyFont: { size: 11 },
      padding: 8,
      cornerRadius: 8,
    },
  },
  elements: {
    point: { radius: 0 },
    line: { tension: 0.4, borderWidth: 2 },
  },
}

const cpuData = computed(() => ({
  labels: labels.value,
  datasets: [{
    label: 'CPU %',
    data: store.samples.map(s => s.cpuPercent),
    borderColor: '#a78bfa',
    backgroundColor: 'rgba(167,139,250,0.06)',
    fill: true,
  }],
}))

const memData = computed(() => ({
  labels: labels.value,
  datasets: [{
    label: 'Memory (MB)',
    data: store.samples.map(s => s.memoryUsedMB),
    borderColor: '#34d399',
    backgroundColor: 'rgba(52,211,153,0.06)',
    fill: true,
  }],
}))

const diskData = computed(() => ({
  labels: labels.value,
  datasets: [
    {
      label: 'Read (KB/s)',
      data: store.samples.map(s => s.diskReadBytes / 1024),
      borderColor: '#fbbf24',
      backgroundColor: 'rgba(251,191,36,0.06)',
      fill: true,
    },
    {
      label: 'Write (KB/s)',
      data: store.samples.map(s => s.diskWriteBytes / 1024),
      borderColor: '#f87171',
      backgroundColor: 'rgba(248,113,113,0.06)',
      fill: true,
    },
  ],
}))

</script>

<template>
  <div v-if="store.samples.length === 0" class="empty" style="padding:48px 0">
    <div style="margin-bottom:12px">
      <svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="var(--text-dim)" stroke-width="1.5" stroke-linecap="round" style="opacity:0.4;animation:dot-pulse 1.4s ease-in-out infinite">
        <polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>
      </svg>
    </div>
    <p>Waiting for metrics data...</p>
  </div>
  <div v-else class="metrics-grid">
    <div class="metric-card">
      <div class="metric-header">
        <h3>CPU Usage</h3>
        <span class="metric-value">{{ store.samples[store.samples.length - 1]?.cpuPercent.toFixed(1) }}%</span>
      </div>
      <div style="height:160px"><Line :data="cpuData" :options="chartOpts" /></div>
    </div>
    <div class="metric-card">
      <div class="metric-header">
        <h3>Memory</h3>
        <span class="metric-value">{{ store.samples[store.samples.length - 1]?.memoryUsedMB }} MB</span>
      </div>
      <div style="height:160px"><Line :data="memData" :options="chartOpts" /></div>
    </div>
    <div class="metric-card">
      <div class="metric-header">
        <h3>Disk I/O</h3>
      </div>
      <div style="height:160px"><Line :data="diskData" :options="chartOpts" /></div>
    </div>
  </div>
</template>

<style scoped>
.metrics-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 14px;
}
.metric-card {
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  padding: 20px;
}
.metric-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 14px;
}
.metric-header h3 {
  margin: 0;
  font-size: 13px;
  font-weight: 600;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.metric-value {
  font-size: 14px;
  font-weight: 700;
  color: var(--accent);
  font-variant-numeric: tabular-nums;
}
</style>
