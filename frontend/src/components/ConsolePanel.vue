<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch } from 'vue'
import { WTerm } from '@wterm/dom'
import '@wterm/dom/src/terminal.css'
import wasmUrl from '@wterm/core/wasm?url'
import { getWSTicket } from '../api/client'

const props = defineProps<{ vmId: string; vmState: string }>()

const isAlive = () => props.vmState === 'running' || props.vmState === 'stopping'

const termEl = ref<HTMLElement>()
const status = ref('')
let terminal: WTerm | null = null
let ws: WebSocket | null = null
let reconnectTimeout: ReturnType<typeof setTimeout> | null = null
let reconnectDelay = 1000
const MAX_RECONNECT_DELAY = 30000
const MAX_RECONNECT_ATTEMPTS = 10
let reconnectAttempts = 0

async function ensureTerminal() {
  if (terminal || !termEl.value) return
  terminal = new WTerm(termEl.value, {
    autoResize: true,
    cursorBlink: true,
    wasmUrl,
    onData: (d) => {
      if (ws?.readyState === WebSocket.OPEN) ws.send(d)
    },
  })
  await terminal.init()
}

async function connect() {
  if (!isAlive()) return
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    status.value = 'Max reconnect attempts reached'
    return
  }

  try {
    await ensureTerminal()
  } catch (e: any) {
    status.value = `Terminal init failed: ${e.message}`
    return
  }

  status.value = 'Requesting ticket...'
  let ticket: string
  try {
    ticket = await getWSTicket(props.vmId)
  } catch (e: any) {
    status.value = `Ticket failed: ${e.response?.data?.reason || e.message}`
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
    terminal?.focus()
  }

  ws.onerror = () => {
    status.value = 'WebSocket error'
  }

  ws.onmessage = (e) => {
    if (terminal) terminal.write(new Uint8Array(e.data))
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
  terminal?.destroy()
  terminal = null
})
</script>

<template>
  <div v-if="vmState !== 'running' && vmState !== 'stopping'" class="empty">VM must be running to use the console</div>
  <div v-else>
    <div v-if="status" style="padding: 8px 12px; font-size: 12px; color: var(--text-dim); background: rgba(255,255,255,0.03); border-bottom: 1px solid var(--border);">
      {{ status }}
    </div>
    <div ref="termEl" class="console-terminal" style="height: 480px; background: #0d0d0d; border-radius: 0; overflow: hidden; border: 1px solid var(--border); box-shadow: 0 4px 24px rgba(0,0,0,0.5);"></div>
  </div>
</template>
