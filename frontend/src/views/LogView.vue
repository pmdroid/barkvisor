<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { useLogStore } from '../stores/logs'
import { useVMStore } from '../stores/vms'
import { getWSTicket } from '../api/client'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import TabGroup from '../components/ui/TabGroup.vue'

const store = useLogStore()
const vmStore = useVMStore()

const category = ref('')
const level = ref('warn')
const search = ref('')
const timeRange = ref('24h')
const liveTail = ref(false)
const vmFilter = ref('')

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

const displayEntries = computed(() => {
  if (!vmFilter.value) return store.entries
  return store.entries.filter(e => e.vm === vmFilter.value)
})

async function refresh() {
  await store.fetchLogs({
    category: category.value || undefined,
    level: level.value || undefined,
    since: sinceFromRange(timeRange.value),
    search: search.value || undefined,
    limit: 1000,
  })
}

function toggleLiveTail() {
  liveTail.value = !liveTail.value
  if (liveTail.value) {
    store.startTail()
  } else {
    store.stopTail()
    refresh()
  }
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

function vmName(id: string): string {
  const vm = vmStore.vms.find(v => v.id === id)
  return vm?.name || id.substring(0, 8)
}

async function downloadDiagnostics() {
  let ticket: string
  try {
    ticket = await getWSTicket()
  } catch { return }
  window.open(`/api/diagnostics/bundle?ticket=${ticket}`, '_blank')
}

watch([category, level, timeRange], () => {
  if (!liveTail.value) refresh()
})

watch(vmFilter, () => {
  // VM filter is client-side, no refetch needed
})

let searchTimeout: ReturnType<typeof setTimeout>
watch(search, () => {
  clearTimeout(searchTimeout)
  searchTimeout = setTimeout(() => {
    if (!liveTail.value) refresh()
  }, 300)
})

onMounted(() => {
  vmStore.fetchAll()
  refresh()
})
onUnmounted(() => store.clear())
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
      <AppSelect v-model="vmFilter">
        <option value="">All VMs</option>
        <option v-for="vm in vmStore.vms" :key="vm.id" :value="vm.id">{{ vm.name }}</option>
      </AppSelect>
      <AppSelect v-model="timeRange">
        <option value="1h">Last Hour</option>
        <option value="6h">Last 6 Hours</option>
        <option value="24h">Last 24 Hours</option>
        <option value="7d">Last 7 Days</option>
        <option value="">All Time</option>
      </AppSelect>
      <AppButton :variant="liveTail ? 'primary' : 'ghost'" style="min-width:140px;text-align:center" @click="toggleLiveTail">{{ liveTail ? 'Stop Tail' : 'Live Tail' }}</AppButton>
      <AppButton icon="download" @click="downloadDiagnostics">Diagnostics</AppButton>
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

  <!-- Empty state -->
  <EmptyState v-if="displayEntries.length === 0 && !store.loading" icon="file" title="No log entries found" subtitle="Try adjusting the time range or level filter" />

  <!-- Loading -->
  <div v-else-if="store.loading && store.entries.length === 0" class="empty">
    <p>Loading logs...</p>
  </div>

  <!-- Log table -->
  <DataTable v-else :columns="[
    { key: 'time', label: 'Time', width: '160px' },
    { key: 'level', label: 'Level', width: '70px' },
    { key: 'source', label: 'Source', width: '80px' },
    { key: 'message', label: 'Message' },
    { key: 'vm', label: 'VM', width: '120px' },
  ]">
      <tr v-for="(entry, i) in displayEntries" :key="i" :class="{ 'row-error': entry.level === 'error' || entry.level === 'fatal', 'row-warn': entry.level === 'warn' }">
        <td class="mono">{{ formatTime(entry.ts) }}</td>
        <td><span class="badge" :class="levelBadge(entry.level)">{{ entry.level }}</span></td>
        <td><span class="badge" :class="catBadge(entry.cat)">{{ entry.cat }}</span></td>
        <td>
          <div style="font-weight:500">{{ entry.msg }}</div>
          <div v-if="entry.err" style="color:var(--red);font-size:11px;margin-top:2px">{{ entry.err }}</div>
        </td>
        <td>
          <button v-if="entry.vm" class="vm-link" @click="vmFilter = entry.vm">{{ vmName(entry.vm) }}</button>
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
