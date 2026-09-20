<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { listWorkloadContainers, type WorkloadContainer } from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { DeviceApiTarget } from '../utils/homeDeviceApi'
import TerminalPanel from './TerminalPanel.vue'
import AppButton from './ui/AppButton.vue'
import AppSelect from './ui/AppSelect.vue'

const props = defineProps<{ vmId: string; vmState: string; device?: DeviceApiTarget | null; active: boolean }>()
const containers = ref<WorkloadContainer[]>([])
const service = ref('')
const error = ref('')
const loading = ref(false)
const sessions = ref<{ id: number; service: string }[]>([])
const activeSession = ref<number | null>(null)
let nextID = 1
const options = computed(() => containers.value.map(c => ({ value: c.service, label: `${c.service} · ${c.state}` })))

function openSession() {
  if (!service.value) return
  const session = { id: nextID++, service: service.value }
  sessions.value.push(session)
  activeSession.value = session.id
}

function closeSession(id: number) {
  sessions.value = sessions.value.filter(session => session.id !== id)
  if (activeSession.value === id) activeSession.value = sessions.value.at(-1)?.id ?? null
}

async function refresh() {
  loading.value = true
  error.value = ''
  try {
    containers.value = await listWorkloadContainers(props.vmId, props.device)
    if (!containers.value.some(c => c.service === service.value)) service.value = containers.value[0]?.service ?? ''
    if (!sessions.value.length) openSession()
  } catch (e) {
    error.value = apiErrorMessage(e)
  } finally {
    loading.value = false
  }
}
onMounted(refresh)
</script>

<template>
  <section class="app-terminals">
    <div class="terminal-controls">
      <AppSelect v-model="service" :options="options" :disabled="loading || !containers.length" />
      <AppButton :disabled="!service || vmState !== 'running'" @click="openSession">New terminal</AppButton>
      <AppButton :loading="loading" @click="refresh">Refresh containers</AppButton>
    </div>
    <p v-if="error" role="alert">{{ error }}</p>
    <p v-else-if="!loading && !containers.length">No containers reported for this app.</p>
    <div class="terminal-controls" role="tablist" aria-label="Terminal sessions">
      <div v-for="session in sessions" :key="session.id">
        <button type="button" role="tab" :aria-selected="activeSession === session.id" @click="activeSession = session.id">{{ session.service }} {{ session.id }}</button>
        <button type="button" aria-label="Close terminal" @click="closeSession(session.id)">×</button>
      </div>
    </div>
    <TerminalPanel v-for="session in sessions" :key="session.id" v-show="session.id === activeSession"
      :vm-id="vmId" :vm-state="vmState" :service="session.service" :device="device"
      :active="active && session.id === activeSession" />
  </section>
</template>

<style scoped>
.terminal-controls { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 12px; }
button[aria-selected="true"] { color: var(--accent); }
</style>
