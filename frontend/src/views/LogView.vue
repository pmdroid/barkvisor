<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import WorkloadDeviceChip from '../components/home/WorkloadDeviceChip.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import TabGroup from '../components/ui/TabGroup.vue'
import { useTaskPoller } from '../composables/useTaskPoller'
import { useDeviceLogsStore, LOG_HISTORY_LIMIT, LOG_TAIL_CAP, type HomeLogRow } from '../stores/deviceLogs'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useLogStore } from '../stores/logs'
import { useToastStore } from '../stores/toast'
import { useVMStore } from '../stores/vms'
import { requestDiagnosticsBundle, saveBlob } from '../utils/diagnosticsBundle'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { isSelfDevice } from '../utils/homeDeviceApi'
import { DEVICE_LABEL } from '../utils/terminology'
import { isDeviceScopeAll, scopeRows } from '../utils/deviceScope'

const store = useLogStore()
const homeLogs = useDeviceLogsStore()
const homeWorkloads = useDeviceWorkloadsStore()
const devicesStore = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const vmStore = useVMStore()
const toast = useToastStore()
const diagnosticsPoller = useTaskPoller()
const diagnosticsBusy = ref(false)

const category = ref('')
const level = ref('warn')
const search = ref('')
const timeRange = ref('24h')
const liveTail = ref(false)
const vmFilter = ref('')
const deviceFilter = ref('')

const categories = [
  { key: '', label: 'All' },
  { key: 'vm', label: 'VM' },
  { key: 'server', label: 'Server' },
  { key: 'app', label: 'App' },
  { key: 'auth', label: 'Auth' },
  { key: 'images', label: 'Images' },
  { key: 'metrics', label: 'Metrics' },
  { key: 'audit', label: 'Audit' },
  { key: 'sync', label: 'Sync' },
]

const useHomeUnion = computed(() => devicesStore.devices.length > 0)

function sinceFromRange(range: string): string | undefined {
  const now = Date.now()
  const offsets: Record<string, number> = {
    '1h': 3600_000,
    '6h': 21600_000,
    '24h': 86400_000,
    '7d': 604800_000,
  }
  if (!offsets[range]) return undefined
  return new Date(now - offsets[range]).toISOString()
}

function fetchParams() {
  return {
    category: category.value || undefined,
    level: level.value || undefined,
    since: sinceFromRange(timeRange.value),
    search: search.value || undefined,
    limit: LOG_HISTORY_LIMIT,
  }
}

const tableColumns = computed(() => {
  const columns = [
    { key: 'time', label: 'Time', width: '160px' },
    { key: 'level', label: 'Level', width: '70px' },
    { key: 'source', label: 'Source', width: '80px' },
    { key: 'message', label: 'Message' },
    { key: 'vm', label: 'VM', width: '120px' },
  ]
  if (!useHomeUnion.value) return columns
  return [
    columns[0]!,
    { key: 'device', label: 'Device', width: '140px' },
    ...columns.slice(1),
  ]
})

const deviceOptions = computed(() =>
  scopeRows(devicesStore.devices, deviceScope.selectedHostId).map((device) => ({
    value: device.hostId,
    label: isSelfDevice(device) ? `This ${DEVICE_LABEL}` : deviceDisplayLabel(device),
  })),
)

const vmOptions = computed(() => {
  if (!useHomeUnion.value) return vmStore.vms.map((vm) => ({ id: vm.id, name: vm.name }))
  const seen = new Set<string>()
  const options: { id: string; name: string }[] = []
  for (const row of scopeRows(homeWorkloads.homeRows(devicesStore.devices), deviceScope.selectedHostId)) {
    if (seen.has(row.vm.id)) continue
    seen.add(row.vm.id)
    options.push({ id: row.vm.id, name: row.vm.name })
  }
  return options
})

const displayRows = computed<HomeLogRow[]>(() => {
  const limit = liveTail.value ? LOG_TAIL_CAP : LOG_HISTORY_LIMIT
  if (useHomeUnion.value) {
    return scopeRows(
      homeLogs.homeRows(devicesStore.devices, limit, {
        hostId: deviceFilter.value || undefined,
        vm: vmFilter.value || undefined,
      }),
      deviceScope.selectedHostId,
    )
  }
  const entries = vmFilter.value
    ? store.entries.filter((item) => item.vm === vmFilter.value)
    : store.entries
  return scopeRows(
    entries.map((item) => ({
      entry: item,
      hostId: devicesStore.selfDevice?.hostId || '',
      label: '',
      role: 'self',
      reachable: true,
    })),
    deviceScope.selectedHostId,
  )
})

const pageLoading = computed(() => {
  if (devicesStore.loading) return true
  if (!useHomeUnion.value) return store.loading
  return devicesStore.devices.some((device) => homeLogs.isLoading(device.hostId))
})

const loadErrors = computed(() =>
  devicesStore.devices
    .map((device) => homeLogs.errorFor(device.hostId))
    .filter((message): message is string => Boolean(message)),
)

async function refresh() {
  await devicesStore.fetchHealth().catch(() => {})
  if (!useHomeUnion.value) {
    await Promise.all([store.fetchLogs(fetchParams()), vmStore.fetchAll()])
    return
  }
  await Promise.all([
    homeLogs.fetchHomeAll(devicesStore.devices, fetchParams()),
    homeWorkloads.fetchHomeAll(devicesStore.devices),
  ])
}

function toggleLiveTail() {
  if (liveTail.value) {
    liveTail.value = false
    homeLogs.stopHomeTail()
    store.stopTail()
    void refresh()
    return
  }
  if (useHomeUnion.value) {
    if (!homeLogs.startHomeTail(devicesStore.devices, fetchParams())) return
    liveTail.value = true
    return
  }
  store.startTail()
  liveTail.value = true
}

function formatTime(ts: string): string {
  try {
    return new Date(ts).toLocaleString([], {
      month: 'short', day: 'numeric',
      hour: '2-digit', minute: '2-digit', second: '2-digit',
    })
  } catch { return ts }
}

function levelBadge(lvl: string): string {
  switch (lvl) {
    case 'error': case 'fatal': return 'badge-red'
    case 'warn': return 'badge-amber'
    case 'info': return 'badge-blue'
    default: return 'badge-gray'
  }
}

function catBadge(cat: string): string {
  switch (cat) {
    case 'vm': return 'badge-purple'
    case 'server': return 'badge-blue'
    case 'auth': return 'badge-amber'
    case 'audit': return 'badge-amber'
    case 'images': return 'badge-green'
    case 'sync': return 'badge-green'
    case 'metrics': return 'badge-gray'
    default: return 'badge-gray'
  }
}

function vmName(row: HomeLogRow): string {
  const id = row.entry.vm
  if (!id) return ''
  if (useHomeUnion.value) {
    return homeWorkloads.vmFor(row.hostId, id)?.name || id.substring(0, 8)
  }
  return vmStore.vms.find((vm) => vm.id === id)?.name || id.substring(0, 8)
}

function rowKey(row: HomeLogRow, index: number): string {
  return `${row.hostId}:${row.entry.ts}:${row.entry.msg}:${index}`
}

async function downloadDiagnostics() {
  if (diagnosticsBusy.value) return
  diagnosticsBusy.value = true
  try {
    await requestDiagnosticsBundle({
      post: (path) => api.post(path),
      poll: (taskID) => diagnosticsPoller.poll(taskID),
      download: (path) => api.get(path, { responseType: 'blob' }),
      save: saveBlob,
    })
  } catch (error) {
    toast.error(apiErrorMessage(error, 'Diagnostic bundle failed'))
  } finally {
    diagnosticsBusy.value = false
  }
}

watch(
  () => deviceScope.selectedHostId,
  (selected) => {
    if (!deviceFilter.value) return
    if (isDeviceScopeAll(selected)) return
    if (deviceFilter.value !== selected) deviceFilter.value = ''
  },
)

watch([category, level, timeRange], () => {
  if (!liveTail.value) void refresh()
})

let searchTimeout: ReturnType<typeof setTimeout>
watch(search, () => {
  clearTimeout(searchTimeout)
  searchTimeout = setTimeout(() => {
    if (!liveTail.value) void refresh()
  }, 300)
})

onMounted(() => {
  void refresh()
})
onUnmounted(() => {
  diagnosticsPoller.stop()
  store.clear()
  homeLogs.clear()
})
</script>

<template>
  <div class="page-header">
    <h1>Logs</h1>
    <div style="display:flex;gap:8px;align-items:center">
      <input
        v-model="search"
        type="text"
        placeholder="Search logs..."
        style="width:220px"
      />
      <AppSelect v-if="useHomeUnion" v-model="deviceFilter">
        <option value="">All Devices</option>
        <option
          v-for="opt in deviceOptions"
          :key="opt.value"
          :value="opt.value"
        >{{ opt.label }}</option>
      </AppSelect>
      <AppSelect v-model="vmFilter">
        <option value="">All VMs</option>
        <option v-for="vm in vmOptions" :key="vm.id" :value="vm.id">{{ vm.name }}</option>
      </AppSelect>
      <AppSelect v-model="timeRange">
        <option value="1h">Last Hour</option>
        <option value="6h">Last 6 Hours</option>
        <option value="24h">Last 24 Hours</option>
        <option value="7d">Last 7 Days</option>
        <option value="">All Time</option>
      </AppSelect>
      <AppButton :variant="liveTail ? 'primary' : 'ghost'" style="min-width:140px;text-align:center" @click="toggleLiveTail">{{ liveTail ? 'Stop Tail' : 'Live Tail' }}</AppButton>
      <AppButton icon="download" :loading="diagnosticsBusy" loading-text="Diagnostics" @click="downloadDiagnostics">Diagnostics</AppButton>
    </div>
  </div>

  <!-- Filter tabs -->
  <div class="log-filters">
    <TabGroup v-model="category" :tabs="categories" />
    <TabGroup v-model="level" :tabs="[
      { key: '', label: 'All' },
      { key: 'info', label: 'Info+' },
      { key: 'warn', label: 'Warn+' },
      { key: 'error', label: 'Errors' },
    ]" />
  </div>

  <p v-if="loadErrors.length" style="color:var(--red, #ef4444);font-size:13px;margin:0 0 12px">
    {{ loadErrors[0] }}
  </p>

  <!-- Empty state -->
  <EmptyState v-if="displayRows.length === 0 && !pageLoading" icon="file" title="No log entries found" subtitle="Try adjusting the time range or level filter" />

  <!-- Loading -->
  <div v-else-if="pageLoading && displayRows.length === 0" class="empty">
    <p>Loading logs...</p>
  </div>

  <!-- Log table -->
  <DataTable v-else :columns="tableColumns">
      <tr v-for="(row, i) in displayRows" :key="rowKey(row, i)" :class="{ 'row-error': row.entry.level === 'error' || row.entry.level === 'fatal', 'row-warn': row.entry.level === 'warn' }">
        <td class="mono">{{ formatTime(row.entry.ts) }}</td>
        <td v-if="useHomeUnion">
          <WorkloadDeviceChip
            :label="row.label"
            :self="row.role === 'self'"
            :reachable="row.reachable"
          />
        </td>
        <td><span class="badge" :class="levelBadge(row.entry.level)">{{ row.entry.level }}</span></td>
        <td><span class="badge" :class="catBadge(row.entry.cat)">{{ row.entry.cat }}</span></td>
        <td>
          <div style="font-weight:500">{{ row.entry.msg }}</div>
          <div v-if="row.entry.err" style="color:var(--red);font-size:11px;margin-top:2px">{{ row.entry.err }}</div>
        </td>
        <td>
          <button v-if="row.entry.vm" class="vm-link" @click="vmFilter = row.entry.vm">{{ vmName(row) }}</button>
        </td>
      </tr>
  </DataTable>
</template>

<style scoped>
.log-filters {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 16px;
}

.row-error td { background: var(--red-muted); }
.row-warn td { background: var(--log-warn-row); }

.vm-link {
  background: none;
  border: none;
  color: var(--blue);
  cursor: pointer;
  font-family: var(--font-mono);
  font-size: 12px;
  padding: 0;
  text-decoration: none;
}
.vm-link:hover {
  text-decoration: underline;
}
</style>
