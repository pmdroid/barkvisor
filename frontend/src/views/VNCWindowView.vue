<script setup lang="ts">
import { ref, onMounted, onUnmounted, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import VNCPanel from '../components/VNCPanel.vue'
import { useVMStore } from '../stores/vms'
import { useDevicesStore } from '../stores/devices'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import type { VM } from '../api/types'
import { apiErrorMessage, isNotFoundError } from '../api/errors'
import { canConnectDeviceConsole } from '../utils/consoleHome'
import { isSelfDevice } from '../utils/homeDeviceApi'

const route = useRoute()
const router = useRouter()
const store = useVMStore()
const devicesStore = useDevicesStore()
const homeWorkloads = useDeviceWorkloadsStore()

const vmId = computed(() => String(route.params.id || ''))
const hostId = computed(() => route.params.hostId ? String(route.params.hostId) : '')
const device = computed(() => (
  hostId.value ? devicesStore.deviceByHostId(hostId.value) : null
))
const memberDevice = computed(() => (
  device.value && !isSelfDevice(device.value) ? device.value : null
))
const loading = ref(true)
const error = ref('')
const vm = ref<VM | null>(null)
let pollTimer: ReturnType<typeof setInterval> | null = null

const vmState = computed(() => vm.value?.state || 'unknown')

async function refresh() {
  if (!vmId.value) return
  try {
    if (hostId.value) {
      await devicesStore.fetchHealth()
      const target = devicesStore.deviceByHostId(hostId.value)
      if (!target) {
        error.value = 'Device not found'
        vm.value = null
        return
      }
      if (!isSelfDevice(target)) {
        if (!canConnectDeviceConsole(target)) {
          error.value = 'This Device did not answer. Connect is hidden until it is reachable.'
          vm.value = null
          return
        }
        try {
          await homeWorkloads.refreshOne(target, vmId.value)
        } catch (e) {
          if (isNotFoundError(e)) {
            homeWorkloads.removeOne(hostId.value, vmId.value)
            error.value = 'Workload not found on that Device'
            vm.value = null
            return
          }
          throw e
        }
        vm.value = homeWorkloads.vmFor(hostId.value, vmId.value) ?? null
        if (!vm.value) {
          error.value = 'Workload not found on that Device'
          return
        }
        error.value = ''
        document.title = vm.value.name ? `${vm.value.name} — VNC` : 'VNC — BarkVisor'
        return
      }
    }
    vm.value = await store.fetchOne(vmId.value)
    error.value = ''
    document.title = vm.value?.name ? `${vm.value.name} — VNC` : 'VNC — BarkVisor'
  } catch (e: any) {
    error.value = apiErrorMessage(e, 'Failed to load VM')
  } finally {
    loading.value = false
  }
}

onMounted(async () => {
  await refresh()
  pollTimer = setInterval(refresh, 5000)
})

onUnmounted(() => {
  if (pollTimer) clearInterval(pollTimer)
})

function backToDetail() {
  if (hostId.value) {
    router.push(`/devices/${encodeURIComponent(hostId.value)}/vms/${vmId.value}?tab=vnc`)
    return
  }
  router.push(`/vms/${vmId.value}?tab=vnc`)
}
</script>

<template>
  <div class="vnc-window-page">
    <div v-if="loading" class="msg">Loading VNC…</div>
    <div v-else-if="error" class="msg">
      {{ error }}
      <button type="button" class="link" @click="backToDetail">Back to VM</button>
    </div>
    <VNCPanel
      v-else
      :vm-id="vmId"
      :vm-state="vmState"
      :device="memberDevice"
      fill
      performance-mode
    />
  </div>
</template>

<style scoped>
.vnc-window-page {
  min-height: 100vh;
  background: #0a0a0a;
  color: #eee;
}
.msg {
  padding: 24px;
  font-size: 14px;
  display: flex;
  gap: 12px;
  align-items: center;
}
.link {
  background: transparent;
  border: 1px solid #444;
  color: #93c5fd;
  border-radius: 6px;
  padding: 4px 10px;
  cursor: pointer;
}
</style>
