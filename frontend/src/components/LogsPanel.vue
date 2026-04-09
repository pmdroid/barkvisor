<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { useLogStore } from '../stores/logs'
import AppButton from './ui/AppButton.vue'
import AppSelect from './ui/AppSelect.vue'

const props = defineProps<{ vmId: string }>()
const store = useLogStore()

const level = ref('')
const category = ref('vm')
const search = ref('')
const liveTail = ref(false)

const displayEntries = computed(() => {
  return store.entries.filter(e => e.vm === props.vmId)
})

async function refresh() {
  await store.fetchLogs({
    category: category.value || undefined,
    level: level.value || undefined,
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

function levelColor(level: string): string {
  switch (level) {
    case 'error': case 'fatal': return 'var(--red)'
    case 'warn': return 'var(--yellow)'
    case 'debug': return 'var(--text-muted)'
    default: return 'var(--text-secondary)'
  }
}

function formatTime(ts: string): string {
  try {
    const d = new Date(ts)
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
  } catch { return ts }
}

watch(level, () => { if (!liveTail.value) refresh() })
watch(category, () => { if (!liveTail.value) refresh() })

let searchTimeout: ReturnType<typeof setTimeout>
watch(search, () => {
  clearTimeout(searchTimeout)
  searchTimeout = setTimeout(() => {
    if (!liveTail.value) refresh()
  }, 300)
})

onMounted(() => refresh())
onUnmounted(() => store.clear())
</script>

<template>
  <div class="logs-panel">
    <div class="toolbar">
      <AppSelect v-model="category" size="sm">
        <option value="">All</option>
        <option value="vm">VM</option>
        <option value="server">Server</option>
        <option value="metrics">Metrics</option>
      </AppSelect>
      <AppSelect v-model="level" size="sm">
        <option value="">All Levels</option>
        <option value="info">Info+</option>
        <option value="warn">Warn+</option>
        <option value="error">Error+</option>
      </AppSelect>
      <input
        v-model="search"
        type="text"
        class="search-input"
        placeholder="Search..."
      />
      <AppButton size="sm" :variant="liveTail ? 'primary' : 'ghost'" style="min-width:140px;text-align:center" @click="toggleLiveTail">
        {{ liveTail ? 'Stop Tail' : 'Live Tail' }}
      </AppButton>
      <AppButton v-if="!liveTail" size="sm" @click="refresh">Refresh</AppButton>
    </div>

    <div v-if="store.loading" class="loading">Loading...</div>

    <div class="log-scroll" v-else>
      <div v-if="displayEntries.length === 0" class="empty">
        No log entries for this VM.
      </div>
      <div
        v-for="(entry, i) in displayEntries"
        :key="i"
        class="log-line"
        :class="'level-' + entry.level"
      >
        <span class="time mono">{{ formatTime(entry.ts) }}</span>
        <span class="lvl" :style="{ color: levelColor(entry.level) }">{{ entry.level }}</span>
        <span class="cat">{{ entry.cat }}</span>
        <span class="msg">{{ entry.msg }}<span v-if="entry.err" class="err"> {{ entry.err }}</span></span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.logs-panel {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 400px;
}

.toolbar {
  display: flex;
  gap: 6px;
  align-items: center;
  margin-bottom: 10px;
}

.search-input {
  background: var(--glass-bg);
  border: 1px solid var(--glass-border);
  border-radius: 6px;
  padding: 5px 10px;
  color: var(--text-primary);
  font-size: 12px;
  flex: 1;
  min-width: 100px;
}

.search-input::placeholder {
  color: var(--text-muted);
}

.loading, .empty {
  color: var(--text-muted);
  padding: 30px;
  text-align: center;
  font-size: 13px;
}

.log-scroll {
  flex: 1;
  overflow-y: auto;
  background: var(--log-dim-bg);
  border-radius: 8px;
  padding: 8px;
  font-family: 'SF Mono', 'Menlo', monospace;
  font-size: 11px;
  line-height: 1.6;
}

.log-line {
  display: flex;
  gap: 8px;
  padding: 1px 4px;
  border-radius: 3px;
}

.log-line.level-error, .log-line.level-fatal {
  background: var(--log-error-bg);
}

.log-line.level-warn {
  background: var(--log-warn-bg);
}

.time {
  color: var(--text-muted);
  flex-shrink: 0;
  width: 70px;
}

.lvl {
  flex-shrink: 0;
  width: 40px;
  font-weight: 600;
  font-size: 10px;
  text-transform: uppercase;
}

.cat {
  color: var(--text-dim);
  flex-shrink: 0;
  width: 50px;
  font-size: 10px;
}

.msg {
  color: var(--text-primary);
  word-break: break-word;
  flex: 1;
}

.err {
  color: var(--red, #ff3b30);
}

.mono {
  font-family: 'SF Mono', 'Menlo', monospace;
}
</style>
