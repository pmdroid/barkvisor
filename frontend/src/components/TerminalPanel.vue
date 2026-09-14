<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref, shallowRef, nextTick, onMounted, onUnmounted, watch, useTemplateRef } from 'vue'
import { Terminal, type TerminalCore, type WTerm } from '@wterm/vue'
import '@wterm/vue/css'
import { GhosttyCore } from '@wterm/ghostty'
import { mintStreamTickets } from '../api/client'
import {
  TERMINAL_CLEAN_CLOSE_CODES,
  terminalNewShellDivider,
  terminalPasteChunks,
  terminalResizeFrame,
  terminalSocketPath,
  terminalSocketQuery,
} from '../utils/terminalSocket'
import { type DeviceApiTarget } from '../utils/homeDeviceApi'

const props = defineProps<{
  vmId: string
  vmState: string
  service: string
  device?: DeviceApiTarget | null
  active?: boolean
}>()

// 'stopping' dropped (#614): a Workload on its way out spawns fresh root shells
// the reconnect machine then cannot talk to — every dial burns a ticket.
const isAlive = () => props.vmState === 'running'

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
// Reconnect state machine (#614). `disposed` kills the ghost reconnects that
// fired after unmount/tab-switch and leaked sockets + `docker exec` children;
// `connecting` is the in-flight dial guard so the vmState watch and the
// reconnect timer can not stack two connects on one component.
let disposed = false
let connecting = false
let everOpened = false

function onReady(instance: WTerm) {
  wt = instance
  // ready may fire after `onopen` (slow ticket mint): the open handler's resize
  // had no grid to measure yet, so push the initial size from this side too.
  // Resize rides both `onReady` and `onopen` so the race cannot lose it (#614).
  if (ws?.readyState === WebSocket.OPEN) sendResize(instance.cols, instance.rows)
  else if (!disposed) void connect()
}

function sendResize(cols: number, rows: number) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(terminalResizeFrame(cols, rows))
}

function onData(data: string) {
  // Binary frames are stdin; text frames are reserved for control (resize).
  // Chunk pastes so no frame passes the daemon/server frame cap (#614).
  if (ws?.readyState !== WebSocket.OPEN) return
  for (const chunk of terminalPasteChunks(data)) ws.send(chunk)
}

function onResize(cols: number, rows: number) {
  sendResize(cols, rows)
}

// A session is kept alive behind v-show when another terminal tab is active.
// ResizeObserver does not reliably fire when its ancestor becomes visible, so
// explicitly reflow and follow the prompt when the user returns to the pane.
function refreshVisibleTerminal() {
  if (!wt) return
  wt.resize(wt.cols, wt.rows)
  wt.element.scrollTop = wt.element.scrollHeight
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
  if (!isAlive()) return
  clearReconnectTimer()
  reconnectTimeout = setTimeout(() => {
    reconnectTimeout = null
    if (!disposed && isAlive()) void connect()
  }, reconnectDelay)
  reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY)
}

async function connect() {
  if (disposed || connecting) return
  if (!isAlive() || !props.service) return
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    status.value = 'Max reconnect attempts reached'
    return
  }

  connecting = true
  status.value = 'Requesting ticket...'
  let ticket: string
  let session: string | undefined
  try {
    const minted = await mintStreamTickets(props.vmId, props.device)
    ticket = minted.ticket
    session = minted.session
  } catch (e: any) {
    connecting = false
    if (disposed) return
    // Mint blips (offline, 5xx during an app restart) are transient: retry on
    // the same backoff ladder instead of parking the pane on one attempt (#614).
    scheduleReconnect(`Ticket failed: ${apiErrorMessage(e)}`)
    return
  }
  if (disposed) {
    // Unmounted while the mint was in flight — do not dial a dead pane.
    connecting = false
    return
  }

  status.value = 'Connecting WebSocket...'
  const wsProto = location.protocol === 'https:' ? 'wss' : 'ws'
  const path = terminalSocketPath(props.device, props.vmId)
  const size = wt ? { cols: wt.cols, rows: wt.rows } : null
  // Initial grid on the connect URL: the daemon blocks on `docker compose ps`
  // before the hop installs frame handlers, so a resize frame that raced that
  // window used to leave an 80×24 shell in a wide grid (#614).
  const socket = new WebSocket(
    `${wsProto}://${location.host}/api${path}?${terminalSocketQuery(ticket, props.service, session, size)}`,
  )
  socket.binaryType = 'arraybuffer'
  ws = socket
  connecting = false

  // Every handler is captured over `socket` and bails when a newer dial (or an
  // unmount) superseded it — stale callbacks must never drive the current one.
  socket.onopen = () => {
    if (disposed || socket !== ws) return
    status.value = ''
    const attempt = reconnectAttempts
    reconnectDelay = 1000
    reconnectAttempts = 0
    if (everOpened) wt?.write(new TextEncoder().encode(terminalNewShellDivider(attempt)))
    everOpened = true
    // Also resize from `onopen`: `ready` may have fired before the socket
    // existed (cached grid) or be pending behind it; sending from both sides
    // closes that race (#614).
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
      // Server status text ("App is not running.", "Terminal unavailable: …")
      // used to be dropped on the floor — the pane looked dead with no reason
      // (#614). Render it.
      target.write(new TextEncoder().encode(e.data))
      return
    }
    target.write(new Uint8Array(e.data as ArrayBuffer))
  }

  socket.onclose = (e) => {
    if (disposed || socket !== ws) return
    ws = null
    if (TERMINAL_CLEAN_CLOSE_CODES.has(e.code)) {
      // Typed `exit`, stopped app, admin-initiated close: the daemon told us so
      // with a text frame + code 1000. Reconnecting here used to storm-spawn
      // root shells up to MAX attempts (#614). Show the reason and stop.
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

watch(() => props.vmState, () => {
  if (disposed || connecting) return
  if (isAlive() && !ws) {
    reconnectAttempts = 0
    reconnectDelay = 1000
    void connect()
  }
})

watch(() => props.active, async (active) => {
  if (!active) return
  await nextTick()
  requestAnimationFrame(refreshVisibleTerminal)
})

onUnmounted(() => {
  disposed = true
  clearReconnectTimer()
  const socket = ws
  ws = null
  if (socket) {
    // Null the handlers before close(): the close event of our own teardown
    // must not enter the reconnect branch (ghost sockets + exec children for
    // unmounted components, #614).
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
  <div v-if="vmState !== 'running'" class="empty">VM must be running to use the terminal</div>
  <div v-else-if="!service" class="empty">Select a container to open a terminal</div>
  <div v-else class="terminal-wrap">
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
