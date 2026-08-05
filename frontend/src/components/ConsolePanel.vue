<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref, onMounted, onUnmounted, watch, useTemplateRef } from 'vue'
import { Terminal, type WTerm } from '@wterm/vue'
import '@wterm/vue/css'
import { getWSTicket } from '../api/client'

const props = defineProps<{ vmId: string; vmState: string }>()

const isAlive = () => props.vmState === 'running' || props.vmState === 'stopping'

const term = useTemplateRef('term')
const status = ref('')
let wt: WTerm | null = null
let ws: WebSocket | null = null
let reconnectTimeout: ReturnType<typeof setTimeout> | null = null
let reconnectDelay = 1000
const MAX_RECONNECT_DELAY = 30000
const MAX_RECONNECT_ATTEMPTS = 10
let reconnectAttempts = 0

function onReady(instance: WTerm) {
  wt = instance
}

function onData(data: string) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(data)
}

function onTermError(err: unknown) {
  status.value = `Terminal failed: ${err instanceof Error ? err.message : String(err)}`
}

async function connect() {
  if (!isAlive()) return
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    status.value = 'Max reconnect attempts reached'
    return
  }

  status.value = 'Requesting ticket...'
  let ticket: string
  try {
    ticket = await getWSTicket(props.vmId)
  } catch (e: any) {
    status.value = `Ticket failed: ${apiErrorMessage(e)}`
    return
  }

  status.value = 'Connecting WebSocket...'
  const wsProto = location.protocol === 'https:' ? 'wss' : 'ws'
  ws = new WebSocket(`${wsProto}://${location.host}/api/vms/${props.vmId}/console?ticket=${ticket}`)
  ws.binaryType = 'arraybuffer'

  ws.onopen = () => {
    status.value = ''
    reconnectDelay = 1000
    reconnectAttempts = 0
  }

  ws.onerror = () => {
    status.value = 'WebSocket error'
  }

  ws.onmessage = (e) => {
    const target = wt ?? term.value
    if (!target) return
    target.write(new Uint8Array(e.data as ArrayBuffer))
  }

  ws.onclose = (e) => {
    ws = null
    reconnectAttempts++
    status.value = `Disconnected (code ${e.code}), reconnecting (${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})...`
    if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      status.value = 'Disconnected — max reconnect attempts reached'
      return
    }
    reconnectTimeout = setTimeout(() => {
      reconnectTimeout = null
      if (isAlive()) connect()
    }, reconnectDelay)
    reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY)
  }
}

onMounted(() => connect())

watch(() => props.vmState, () => {
  if (isAlive() && !ws) {
    reconnectAttempts = 0
    reconnectDelay = 1000
    connect()
  }
})

onUnmounted(() => {
  if (reconnectTimeout) { clearTimeout(reconnectTimeout); reconnectTimeout = null }
  ws?.close()
  ws = null
  wt = null
})
</script>

<template>
  <div v-if="vmState !== 'running' && vmState !== 'stopping'" class="empty">VM must be running to use the console</div>
  <div v-else class="console-wrap">
    <div v-if="status" class="console-status">
      {{ status }}
    </div>
    <Terminal
      ref="term"
      class="console-term"
      cursor-blink
      auto-resize
      @ready="onReady"
      @data="onData"
      @error="onTermError"
    />
  </div>
</template>

<style scoped>
.console-wrap {
  border: 1px solid var(--border);
  box-shadow: 0 4px 24px rgba(0, 0, 0, 0.5);
  overflow: hidden;
}

.console-status {
  padding: 8px 12px;
  font-size: 12px;
  color: var(--text-dim);
  background: rgba(255, 255, 255, 0.03);
  border-bottom: 1px solid var(--border);
}

.console-term {
  height: 480px;
  --term-bg: #0d0d0d;
  --term-fg: #e8e8e8;
  --term-font-family: 'JetBrains Mono', Menlo, monospace;
  --term-font-size: 14px;
  border-radius: 0;
  box-shadow: none;
  padding: 8px;
}
</style>
