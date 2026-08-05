<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch, computed } from 'vue'
import rfbModule from '@novnc/novnc/lib/rfb.js'
const RFB = (rfbModule as any).default || rfbModule
import { getWSTicket } from '../api/client'

const props = withDefaults(
  defineProps<{
    vmId: string
    vmState: string
    /** Fill parent (popup window); otherwise fixed-height embed */
    fill?: boolean
    /** Prefer lower quality / higher JPEG for smoother remote display */
    performanceMode?: boolean
  }>(),
  { fill: false, performanceMode: true },
)

const isAlive = () => props.vmState === 'running' || props.vmState === 'stopping'

const canvasEl = ref<HTMLElement>()
const status = ref('disconnected')
const desktopSize = ref('')
let rfb: any = null
let reconnectTimeout: ReturnType<typeof setTimeout> | null = null
let reconnectDelay = 1000
const MAX_RECONNECT_DELAY = 30000
const MAX_RECONNECT_ATTEMPTS = 10
let reconnectAttempts = 0

const statusLabel = computed(() => {
  if (status.value === 'connected' && desktopSize.value) {
    return `connected · ${desktopSize.value}`
  }
  return status.value
})

function applyPerfSettings(client: any) {
  // qualityLevel: 0–9 (higher = sharper, more bandwidth). Prefer mid-low for smoothness.
  client.qualityLevel = props.performanceMode ? 4 : 6
  // compressionLevel: 0–9 (higher = more zlib CPU, less bandwidth). Keep modest on weak hosts.
  client.compressionLevel = props.performanceMode ? 2 : 2
  client.scaleViewport = true
  // Ask the guest (via ExtendedDesktopSize) to match the container — fewer pixels = less lag.
  client.resizeSession = true
  client.clipViewport = false
  client.focusOnClick = true
  client.showDotCursor = false
}

async function connect() {
  if (!isAlive() || !canvasEl.value) return
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
    status.value = 'max reconnects'
    return
  }

  status.value = 'connecting'
  let ticket: string
  try {
    ticket = await getWSTicket(props.vmId)
  } catch {
    status.value = 'ticket failed'
    return
  }

  // Tear down previous client if any
  try { rfb?.disconnect() } catch { /* ignore */ }
  rfb = null

  const wsProto = location.protocol === 'https:' ? 'wss' : 'ws'
  const url = `${wsProto}://${location.host}/api/vms/${props.vmId}/vnc?ticket=${ticket}`
  rfb = new RFB(canvasEl.value, url, { credentials: { password: '' } })
  applyPerfSettings(rfb)

  rfb.addEventListener('connect', () => {
    status.value = 'connected'
    reconnectDelay = 1000
    reconnectAttempts = 0
    try {
      const w = rfb?._fbWidth ?? rfb?._display?.width
      const h = rfb?._fbHeight ?? rfb?._display?.height
      if (w && h) desktopSize.value = `${w}×${h}`
    } catch { /* ignore */ }
    rfb.focus()
  })

  rfb.addEventListener('desktopname', (e: any) => {
    if (e?.detail?.name) document.title = `${e.detail.name} — VNC`
  })

  rfb.addEventListener('disconnect', () => {
    status.value = 'disconnected'
    desktopSize.value = ''
    rfb = null
    reconnectAttempts++
    if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
      status.value = 'max reconnects'
      return
    }
    reconnectTimeout = setTimeout(() => {
      reconnectTimeout = null
      if (isAlive()) connect()
    }, reconnectDelay)
    reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY)
  })
}

function openInNewWindow() {
  const w = Math.min(1400, screen.availWidth - 40)
  const h = Math.min(900, screen.availHeight - 60)
  const left = Math.max(0, Math.floor((screen.availWidth - w) / 2))
  const top = Math.max(0, Math.floor((screen.availHeight - h) / 2))
  const features = `popup=yes,width=${w},height=${h},left=${left},top=${top},resizable=yes,scrollbars=no`
  window.open(`/vms/${props.vmId}/vnc`, `barkvisor-vnc-${props.vmId}`, features)
}

function sendCtrlAltDel() {
  rfb?.sendCtrlAltDel?.()
}

onMounted(() => connect())

watch(() => props.vmState, () => {
  if (isAlive() && !rfb) {
    reconnectAttempts = 0
    reconnectDelay = 1000
    connect()
  }
})

onUnmounted(() => {
  if (reconnectTimeout) { clearTimeout(reconnectTimeout); reconnectTimeout = null }
  try { rfb?.disconnect() } catch { /* ignore */ }
  rfb = null
})
</script>

<template>
  <div v-if="vmState !== 'running' && vmState !== 'stopping'" class="empty">
    VM must be running to use VNC
  </div>
  <div v-else class="vnc-root" :class="{ fill }">
    <div class="vnc-toolbar">
      <span class="vnc-status">VNC: {{ statusLabel }}</span>
      <div class="vnc-actions">
        <button type="button" class="vnc-btn" title="Send Ctrl+Alt+Del" @click="sendCtrlAltDel">
          Ctrl+Alt+Del
        </button>
        <button
          v-if="!fill"
          type="button"
          class="vnc-btn primary"
          title="Open VNC in a resizable window"
          @click="openInNewWindow"
        >
          Open in new window
        </button>
      </div>
    </div>
    <div ref="canvasEl" class="vnc-canvas" />
  </div>
</template>

<style scoped>
.vnc-root {
  display: flex;
  flex-direction: column;
  gap: 0;
  min-height: 0;
}
.vnc-root.fill {
  position: fixed;
  inset: 0;
  background: #0a0a0a;
  z-index: 1;
}
.vnc-toolbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 8px 12px;
  font-size: 12px;
  color: var(--text-dim, #999);
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid var(--border, #333);
  border-bottom: none;
  flex-shrink: 0;
}
.vnc-root.fill .vnc-toolbar {
  border: none;
  border-bottom: 1px solid #222;
  background: #111;
}
.vnc-status {
  font-variant-numeric: tabular-nums;
}
.vnc-actions {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
}
.vnc-btn {
  font-size: 12px;
  padding: 4px 10px;
  border-radius: 6px;
  border: 1px solid var(--border, #444);
  background: transparent;
  color: var(--text, #eee);
  cursor: pointer;
}
.vnc-btn:hover {
  background: rgba(255, 255, 255, 0.06);
}
.vnc-btn.primary {
  border-color: var(--accent, #3b82f6);
  color: var(--accent, #3b82f6);
}
.vnc-canvas {
  background: #000;
  overflow: hidden;
  border: 1px solid var(--border, #333);
  box-shadow: 0 4px 24px rgba(0, 0, 0, 0.5);
  width: 100%;
  height: 600px;
  min-height: 0;
  flex: 1 1 auto;
}
.vnc-root.fill .vnc-canvas {
  border: none;
  box-shadow: none;
  height: auto;
}
.empty {
  padding: 16px;
  color: var(--text-dim, #999);
}
</style>
