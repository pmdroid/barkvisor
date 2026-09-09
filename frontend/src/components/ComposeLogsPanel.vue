<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import api from '../api/client'
import { useTicketedEventSource } from '../composables/useTicketedEventSource'
import { shouldPollDeviceControl } from '../utils/editHome'
import { devicePath, type DeviceApiTarget } from '../utils/homeDeviceApi'
import { firstPasswordFromLogs, isFirstPasswordLine } from '../utils/composeLogs'
import AppButton from './ui/AppButton.vue'

const props = defineProps<{ vmId: string; device?: DeviceApiTarget | null }>()

const lines = ref<string[]>([])
const loading = ref(false)
const stream = useTicketedEventSource()
let pollTimer: ReturnType<typeof setInterval> | undefined
let epoch = 0

const hint = computed(() => firstPasswordFromLogs(lines.value))
const snapshotPath = computed(() => {
  const local = `/vms/${encodeURIComponent(props.vmId)}/logs`
  return props.device ? devicePath(props.device, local) : local
})

async function loadSnapshot(epochAtStart: number) {
  loading.value = true
  try {
    const { data } = await api.get<{ lines?: string[] }>(snapshotPath.value, { params: { tail: 200 } })
    if (epochAtStart !== epoch) return
    lines.value = Array.isArray(data?.lines) ? data.lines : []
  } catch {
    if (epochAtStart !== epoch) return
  } finally {
    if (epochAtStart === epoch) loading.value = false
  }
}

function connect() {
  disconnect()
  const myEpoch = ++epoch
  lines.value = []
  if (props.device && shouldPollDeviceControl(props.device)) {
    void loadSnapshot(myEpoch)
    pollTimer = globalThis.setInterval(() => {
      void loadSnapshot(myEpoch)
    }, 3000)
    return
  }
  void loadSnapshot(myEpoch)
  stream.start({
    vmID: props.vmId,
    url: (ticket) => `/api/vms/${encodeURIComponent(props.vmId)}/logs/stream?ticket=${ticket}`,
    reconnect: true,
    onMessage: (event) => {
      try {
        const payload = JSON.parse(event.data) as { line?: string }
        if (payload.line) lines.value = [...lines.value, payload.line].slice(-2000)
      } catch {
        if (event.data) lines.value = [...lines.value, event.data].slice(-2000)
      }
    },
  })
}

function disconnect() {
  epoch++
  if (pollTimer) {
    clearInterval(pollTimer)
    pollTimer = undefined
  }
  stream.stop()
}

function downloadLogs() {
  const blob = new Blob([`${lines.value.join('\n')}\n`], { type: 'text/plain' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `${props.vmId}-compose.log`
  a.click()
  URL.revokeObjectURL(url)
}

watch(
  () => [props.vmId, props.device?.hostId, props.device?.reachability] as const,
  () => { connect() },
)

onMounted(() => connect())
onUnmounted(() => disconnect())
</script>

<template>
  <div class="compose-logs">
    <div v-if="hint" class="ops-banner amber password-banner">
      <div>
        <div class="ops-banner-title">Temporary password from logs</div>
        <div class="ops-banner-sub">qBittorrent prints the first password here. <span class="mono">{{ hint }}</span></div>
      </div>
    </div>
    <div class="panel">
      <div class="log-toolbar">
        <h2>Logs</h2>
        <div class="log-actions">
          <span class="log-hint">docker compose logs · last 200 lines · following</span>
          <AppButton size="sm" @click="downloadLogs">Download</AppButton>
        </div>
      </div>
      <div class="terminal">
        <div v-if="loading && lines.length === 0" class="empty">Loading...</div>
        <div v-else-if="lines.length === 0" class="empty">No compose logs yet.</div>
        <div
          v-for="(line, i) in lines"
          :key="i"
          class="line"
          :class="{ warn: isFirstPasswordLine(line) }"
        >{{ line }}</div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.compose-logs { display: flex; flex-direction: column; gap: 14px; }
.password-banner { margin-bottom: 0; }
.panel {
  background: var(--bg-card);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  overflow: hidden;
}
.log-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px 18px;
  border-bottom: 1px solid var(--border);
}
.log-toolbar h2 {
  margin: 0;
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--text-dim);
}
.log-actions { display: flex; gap: 8px; align-items: center; }
.log-hint { font-size: 11.5px; color: var(--text-dim); }
.terminal {
  background: #070a10;
  padding: 16px 18px;
  font-family: ui-monospace, 'SF Mono', monospace;
  font-size: 12px;
  line-height: 1.7;
  overflow-x: auto;
  min-height: 320px;
  max-height: 560px;
  overflow-y: auto;
}
.line { white-space: pre; color: var(--text-secondary); }
.line.warn { color: var(--amber); }
.empty { color: var(--text-dim); }
.mono { font-family: ui-monospace, 'SF Mono', monospace; font-size: 12px; }
</style>
