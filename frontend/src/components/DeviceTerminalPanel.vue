<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { mintDeviceTerminalTickets } from '../api/client'
import { ref, shallowRef, onMounted, onUnmounted, useTemplateRef } from 'vue'
import { Terminal, type TerminalCore, type WTerm } from '@wterm/vue'
import '@wterm/vue/css'
import { GhosttyCore } from '@wterm/ghostty'
import {
  TERMINAL_CLEAN_CLOSE_CODES,
  terminalNewShellDivider,
  terminalPasteChunks,
  terminalResizeFrame,
  deviceTerminalSocketPath,
  deviceTerminalSocketQuery,
} from '../utils/terminalSocket'
import { type DeviceApiTarget } from '../utils/homeDeviceApi'

const props = defineProps<{
  osUser: string
  device?: DeviceApiTarget | null
}>()

const term = useTemplateRef('term')
const status = ref('')
const terminalCore = shallowRef<TerminalCore | null>(null)
let wt: WTerm | null = null
let ws: WebSocket | null = null
let reconnectTimeout: ReturnType<typeof setTimeout> | null = null
let reconnectDelay = 1000
const MAX_RECONNECT_DELAY = 30000
const MAX_RECONNECT_ATTEMPTS = 10
let reconnectAttempts = 0
let disposed = false
let connecting = false
let everOpened = false
let outputFollowFrame: number | null = null

function onReady(instance: WTerm) {
  wt = instance
  if (ws?.readyState === WebSocket.OPEN) sendResize(instance.cols, instance.rows)
  else if (!disposed) void connect()
}

function sendResize(cols: number, rows: number) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(terminalResizeFrame(cols, rows))
}

function onData(data: string) {
  if (ws?.readyState !== WebSocket.OPEN) return
  for (const chunk of terminalPasteChunks(data)) ws.send(chunk)
}

function onResize(cols: number, rows: number) {
  sendResize(cols, rows)
}

function followLiveOutput() {
  if (!wt || outputFollowFrame !== null) return
  outputFollowFrame = requestAnimationFrame(() => {
    outputFollowFrame = null
    if (wt) wt.element.scrollTop = wt.element.scrollHeight
  })
}

function onTermError(err: unknown) {
  status.value = `Terminal failed: ${err instanceof Error ? err.message : String(err)}`
}

function clearReconnectTimer() {
  if (reconnectTimeout) {
    clearTimeout(reconnectTimeout)
    reconnectTimeout = null
  }
}

function scheduleReconnect(reason: string) {
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    status.value = 'Disconnected — max reconnect attempts reached'
    return
  }
  reconnectAttempts++
  status.value = `${reason}, reconnecting (${reconnectAttempts}/${MAX_RECONNECT_ATTEMPTS})...`
  clearReconnectTimer()
  reconnectTimeout = setTimeout(() => {
    reconnectTimeout = null
    if (!disposed) void connect()
  }, reconnectDelay)
  reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY)
}

async function connect() {
  if (disposed || connecting) return
  if (!props.osUser) return
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    status.value = 'Max reconnect attempts reached'
    return
  }

  connecting = true
  status.value = 'Requesting ticket...'
  let ticket: string
  let session: string | undefined
  try {
    const minted = await mintDeviceTerminalTickets(props.osUser, props.device)
    ticket = minted.ticket
    session = minted.session
  } catch (e: unknown) {
    connecting = false
    if (disposed) return
    scheduleReconnect(`Ticket failed: ${apiErrorMessage(e)}`)
    return
  }
  if (disposed) {
    connecting = false
    return
  }

  status.value = 'Connecting WebSocket...'
  const wsProto = location.protocol === 'https:' ? 'wss' : 'ws'
  const path = deviceTerminalSocketPath(props.device)
  const size = wt ? { cols: wt.cols, rows: wt.rows } : null
  const socket = new WebSocket(
    `${wsProto}://${location.host}/api${path}?${deviceTerminalSocketQuery(ticket, session, size)}`,
  )
  socket.binaryType = 'arraybuffer'
  ws = socket
  connecting = false

  socket.onopen = () => {
    if (disposed || socket !== ws) return
    status.value = ''
    const attempt = reconnectAttempts
    reconnectDelay = 1000
    reconnectAttempts = 0
    if (everOpened) wt?.write(new TextEncoder().encode(terminalNewShellDivider(attempt)))
    everOpened = true
    if (wt) sendResize(wt.cols, wt.rows)
  }

  socket.onerror = () => {
    if (disposed || socket !== ws) return
    status.value = 'WebSocket error'
  }

  socket.onmessage = (e) => {
    if (disposed || socket !== ws) return
    const target = wt ?? term.value
    if (!target) return
    if (typeof e.data === 'string') {
      target.write(new TextEncoder().encode(e.data))
      followLiveOutput()
      return
    }
    target.write(new Uint8Array(e.data as ArrayBuffer))
    followLiveOutput()
  }

  socket.onclose = (e) => {
    if (disposed || socket !== ws) return
    ws = null
    if (TERMINAL_CLEAN_CLOSE_CODES.has(e.code)) {
      status.value = 'Shell closed'
      reconnectAttempts = 0
      reconnectDelay = 1000
      return
    }
    scheduleReconnect(`Disconnected (code ${e.code})`)
  }
}

onMounted(async () => {
  try {
    terminalCore.value = await GhosttyCore.load({
      foregroundColor: '#e8e8e8',
      backgroundColor: '#0d0d0d',
    })
  } catch (error) {
    status.value = `Terminal failed to initialize: ${error instanceof Error ? error.message : String(error)}`
  }
})

onUnmounted(() => {
  disposed = true
  clearReconnectTimer()
  if (outputFollowFrame !== null) {
    cancelAnimationFrame(outputFollowFrame)
    outputFollowFrame = null
  }
  const socket = ws
  ws = null
  if (socket) {
    socket.onopen = null
    socket.onerror = null
    socket.onmessage = null
    socket.onclose = null
    socket.close()
  }
  wt = null
})
</script>

<template>
  <div class="terminal-wrap">
    <div v-if="status" class="terminal-status">
      {{ status }}
    </div>
    <Terminal
      v-if="terminalCore"
      ref="term"
      class="terminal-term"
      :core="terminalCore"
      cursor-blink
      auto-resize
      @ready="onReady"
      @data="onData"
      @resize="onResize"
      @error="onTermError"
    />
  </div>
</template>

<style scoped>
.terminal-wrap {
  border: 1px solid var(--border);
  box-shadow: 0 4px 24px rgba(0, 0, 0, 0.5);
  overflow: hidden;
}

.terminal-status {
  padding: 8px 12px;
  font-size: 12px;
  color: var(--text-dim);
  background: rgba(255, 255, 255, 0.03);
  border-bottom: 1px solid var(--border);
}

.terminal-term {
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
