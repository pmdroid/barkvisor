<script setup lang="ts">
import { ref, onMounted, onUnmounted, computed } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import VNCPanel from '../components/VNCPanel.vue'
import { useVMStore } from '../stores/vms'
import type { VM } from '../api/types'
import { apiErrorMessage } from '../api/errors'

const route = useRoute()
const router = useRouter()
const store = useVMStore()

const vmId = computed(() => String(route.params.id || ''))
const loading = ref(true)
const error = ref('')
const vm = ref<VM | null>(null)
let pollTimer: ReturnType<typeof setInterval> | null = null

const vmState = computed(() => vm.value?.state || 'unknown')

async function refresh() {
  if (!vmId.value) return
  try {
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
