<script setup lang="ts">
import { ref, onMounted, onUnmounted, watch } from 'vue'
import rfbModule from '@novnc/novnc/lib/rfb.js'
const RFB = (rfbModule as any).default || rfbModule
import { getWSTicket } from '../api/client'

const props = defineProps<{ vmId: string; vmState: string }>()

const isAlive = () => props.vmState === 'running' || props.vmState === 'stopping'

const canvasEl = ref<HTMLElement>()
const status = ref('disconnected')
let rfb: any = null
let reconnectTimeout: ReturnType<typeof setTimeout> | null = null
let reconnectDelay = 1000
const MAX_RECONNECT_DELAY = 30000
const MAX_RECONNECT_ATTEMPTS = 10
let reconnectAttempts = 0

async function connect() {
  if (!isAlive() || !canvasEl.value) return
  if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) return

  let ticket: string
  try {
    ticket = await getWSTicket(props.vmId)
  } catch { return }

  const wsProto = location.protocol === 'https:' ? 'wss' : 'ws'
  const url = `${wsProto}://${location.host}/api/vms/${props.vmId}/vnc?ticket=${ticket}`
  rfb = new RFB(canvasEl.value, url, { credentials: { password: '' } })
  rfb.scaleViewport = true
  rfb.resizeSession = false
  rfb.focusOnClick = true
  rfb.addEventListener('connect', () => {
    status.value = 'connected'
    reconnectDelay = 1000
    reconnectAttempts = 0
    rfb.focus()
  })
  rfb.addEventListener('disconnect', () => {
    status.value = 'disconnected'
    rfb = null
    reconnectAttempts++
    if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) return
    reconnectTimeout = setTimeout(() => {
      reconnectTimeout = null
      if (isAlive()) connect()
    }, reconnectDelay)
    reconnectDelay = Math.min(reconnectDelay * 2, MAX_RECONNECT_DELAY)
  })
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
  rfb?.disconnect()
  rfb = null
})
</script>

<template>
  <div v-if="vmState !== 'running' && vmState !== 'stopping'" class="empty">VM must be running to use VNC</div>
  <div v-else>
    <div style="margin-bottom: 8px; font-size: 12px; color: var(--text-dim)">
      VNC: {{ status }}
    </div>
    <div ref="canvasEl" style="background: #000; border-radius: 0; overflow: hidden; border: 1px solid var(--border); box-shadow: 0 4px 24px rgba(0,0,0,0.5); width: 100%; height: 600px;"></div>
  </div>
</template>
