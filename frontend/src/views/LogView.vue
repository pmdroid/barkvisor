<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import EmptyState from '../components/ui/EmptyState.vue'
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
import { formatLogClock, parseLogDate } from '../utils/format'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'
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
const level = ref('')
const search = ref('')
const timeRange = ref('24h')
const liveTail = ref(false)
const vmFilter = ref('')
const deviceFilter = ref('')
const hideBefore = ref(0)

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

const deviceOptions = computed(() =>
  scopeRows(devicesStore.devices, deviceScope.selectedHostId).map((device) => ({
    value: device.hostId,
    label: deviceDisplayLabel(device),
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

const rawRows = computed<HomeLogRow[]>(() => {
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

const displayRows = computed<HomeLogRow[]>(() => {
  const rows = [...rawRows.value].reverse()
  if (!hideBefore.value) return rows
  return rows.filter((row) => {
    const parsed = parseLogDate(row.entry.ts)
    return parsed ? parsed.getTime() >= hideBefore.value : true
  })
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

function lineClass(level: string): string {
  if (level === 'error' || level === 'fatal') return 'err'
  if (level === 'warn') return 'warn-l'
  return ''
}

function levelClass(level: string): string {
  if (level === 'error' || level === 'fatal') return 'error'
  if (level === 'warn') return 'warn'
  return 'info'
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

const scopeNote = computed(() => {
  const deviceLabel = deviceFilter.value
    ? deviceOptions.value.find((opt) => opt.value === deviceFilter.value)?.label ?? deviceFilter.value
    : `All ${DEVICE_LABEL}s`
  const vmLabel = vmFilter.value
    ? vmOptions.value.find((opt) => opt.id === vmFilter.value)?.name ?? vmFilter.value
    : 'All Workloads'
  return `${HOME_LABEL} · ${deviceLabel} · ${vmLabel} · ${liveTail.value ? 'following' : 'history'}`
})

const cursorClock = computed(() => {
  const last = displayRows.value[displayRows.value.length - 1]
  if (!last) return formatLogClock(Date.now())
  return formatLogClock(last.entry.ts)
})

function clearStream() {
  hideBefore.value = Date.now()
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
  <div class="ops-page">
  <div class="ops-toolbar log-toolbar page-header">
    <h1>Logs</h1>
    <div class="ops-actions">
      <input
        v-model="search"
        class="ops-search"
        type="search"
        placeholder="Search messages"
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
        <option value="">All Workloads</option>
        <option v-for="vm in vmOptions" :key="vm.id" :value="vm.id">{{ vm.name }}</option>
      </AppSelect>
      <AppSelect v-model="timeRange">
        <option value="24h">Last 24 Hours</option>
        <option value="1h">Last Hour</option>
        <option value="7d">Last 7 Days</option>
      </AppSelect>
      <AppButton
        :class="{ 'btn-live': liveTail, 'btn-live-active': liveTail }"
        @click="toggleLiveTail"
      >
        <span class="ops-dot" :class="liveTail ? 'ok pulse' : 'off'"></span>
        Live Tail
      </AppButton>
      <AppButton icon="download" :loading="diagnosticsBusy" loading-text="Diagnostics" @click="downloadDiagnostics">Diagnostics</AppButton>
    </div>
  </div>
  <div class="ops-body term-body">

  <p v-if="loadErrors.length" style="color:var(--red, #ef4444);font-size:13px;margin:12px 16px 0">
    {{ loadErrors[0] }}
  </p>

  <div class="term">
    <div class="term-head">
      <span class="ttl"><span class="ops-dot" :class="liveTail ? 'ok pulse' : 'off'"></span>{{ liveTail ? 'Live tail' : 'History' }}</span>
      <span class="scope-note">{{ scopeNote }}</span>
      <div class="rhs">
        <button type="button" class="mini" @click="toggleLiveTail">{{ liveTail ? 'Pause' : 'Resume' }}</button>
        <button type="button" class="mini" @click="clearStream">Clear</button>
      </div>
    </div>
    <EmptyState v-if="displayRows.length === 0 && !pageLoading" icon="file" title="No log entries found" subtitle="Try adjusting the time range or search" />
    <div v-else-if="pageLoading && displayRows.length === 0" class="empty">
      <p>Loading logs...</p>
    </div>
    <div v-else class="stream">
      <div
        v-for="(row, i) in displayRows"
        :key="rowKey(row, i)"
        class="line"
        :class="lineClass(row.entry.level)"
      >
        <span class="lt">{{ formatLogClock(row.entry.ts) }}</span>
        <span class="lv" :class="levelClass(row.entry.level)">{{ row.entry.level.toUpperCase() }}</span>
        <span class="lsrc">{{ row.entry.cat }}</span>
        <span v-if="useHomeUnion" class="ldev">{{ row.label }}</span>
        <span class="lmsg">{{ row.entry.msg }}<template v-if="row.entry.err"> — {{ row.entry.err }}</template></span>
        <span v-if="row.entry.vm" class="lvm">[{{ vmName(row) }}]</span>
      </div>
      <div v-if="liveTail" class="cursor-line">
        <span class="lt">{{ cursorClock }}</span>
        <span class="blink"></span>
      </div>
    </div>
  </div>
  </div>
  </div>
</template>

<style scoped>
.log-toolbar {
  height: 58px;
  flex-wrap: nowrap;
  padding-top: 0;
  padding-bottom: 0;
}
.ops-toolbar.page-header {
  margin-bottom: 0;
}
</style>
