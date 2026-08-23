<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { apiErrorMessage } from '../api/errors'
import type { OllamaCatalogModel } from '../api/types'
import AppButton from '../components/ui/AppButton.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import { useTaskPoller } from '../composables/useTaskPoller'
import { useAuthStore } from '../stores/auth'
import { useOllamaStore } from '../stores/ollama'
import { useToastStore } from '../stores/toast'
import { formatBytes } from '../utils/format'
import { useDevicesStore } from '../stores/devices'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'

const auth = useAuthStore()
const store = useOllamaStore()
const devices = useDevicesStore()
const toast = useToastStore()
const poller = useTaskPoller()
const pullName = ref('')
const pullHost = ref('')
const pulling = ref(false)
const apiKeyDraft = ref('')
const keySaving = ref(false)

const hostOptions = computed(() =>
  store.devices
    .filter((row) => row.reachable)
    .map((row) => ({
      value: row.hostId,
      label: row.displayName?.trim() || row.hostId,
    })),
)

let pollTimer: number
onMounted(() => {
  void store.fetchCatalog()
  if (auth.isAdmin) {
    void store.fetchSettings()
    void devices.fetchHealth()
  }
  pollTimer = window.setInterval(() => { void store.fetchCatalog() }, 10_000)
})
onUnmounted(() => clearInterval(pollTimer))

function locationLabel(model: OllamaCatalogModel): string {
  return model.locations
    .map((loc) => {
      const name = loc.displayName?.trim() || loc.hostId
      return loc.running ? `${name} (running)` : name
    })
    .join(', ')
}

async function pullModel() {
  const name = pullName.value.trim()
  if (!name) return
  pulling.value = true
  try {
    const task = await store.pull(name, pullHost.value || undefined)
    const path =
      task.hostId === devices.selfDevice?.hostId
        ? undefined
        : `/home/devices/${task.hostId}/v1/tasks/${task.taskID}`
    await poller.poll(task.taskID, {
      path,
      onComplete: () => {
        toast.success(`Ollama pulled ${name}`)
        void store.fetchCatalog()
      },
      onFailed: (event) => {
        toast.error(event.error || `Ollama could not pull ${name}`)
      },
    })
    pullName.value = ''
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    pulling.value = false
  }
}

async function startModel(model: OllamaCatalogModel) {
  try {
    await store.start(model.name, model.locations[0]?.hostId)
    toast.success(`Ollama loaded ${model.name}`)
    await store.fetchCatalog()
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  }
}

async function stopModel(model: OllamaCatalogModel) {
  try {
    await store.stop(model.name, model.locations.find((loc) => loc.running)?.hostId)
    toast.success(`Ollama unloaded ${model.name}`)
    await store.fetchCatalog()
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  }
}

async function saveKey() {
  keySaving.value = true
  try {
    await store.saveSettings({ apiKey: apiKeyDraft.value })
    apiKeyDraft.value = ''
    toast.success('Ollama API key saved on this Device')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    keySaving.value = false
  }
}
</script>

<template>
  <div class="page-header">
    <div>
      <h1>Ollama</h1>
      <p class="welcome-sub">
        Models on this {{ HOME_LABEL }}. Completions go to the Device that already has the model.
      </p>
    </div>
  </div>

  <EmptyState
    v-if="!store.anyReachable && !store.loading"
    icon="monitor"
    title="Ollama is not reachable"
    :subtitle="store.devices[0]?.installHint || 'Install Ollama on a Device to manage models here.'"
  />

  <template v-else>
    <div v-if="auth.isAdmin" class="card" style="margin-bottom:16px">
      <div class="form-group" style="margin:0">
        <label>Pull a model</label>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <input v-model="pullName" placeholder="llama3" style="flex:1;min-width:160px" />
          <select v-model="pullHost" style="min-width:160px">
            <option value="">Any reachable {{ DEVICE_LABEL }}</option>
            <option v-for="opt in hostOptions" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
          </select>
          <AppButton variant="primary" :disabled="!pullName.trim()" :loading="pulling" loading-text="Pulling..." @click="pullModel">
            Pull
          </AppButton>
        </div>
      </div>
    </div>

    <EmptyState
      v-if="store.models.length === 0 && !store.loading"
      icon="monitor"
      title="No Ollama models yet"
      subtitle="Pull a model to open Chat. Completions go through /v1/chat/completions."
    />

    <DataTable
      v-else
      :columns="[
        { key: 'name', label: 'Model' },
        { key: 'size', label: 'Size' },
        { key: 'where', label: DEVICE_LABEL },
        { key: 'state', label: 'State' },
        ...(auth.isAdmin ? [{ key: 'actions', label: '', align: 'right' as const }] : []),
      ]"
    >
      <tr v-for="model in store.models" :key="model.name">
        <td style="font-weight:500">{{ model.name }}</td>
        <td style="color:var(--text-secondary)">{{ model.size ? formatBytes(model.size) : '—' }}</td>
        <td style="color:var(--text-secondary)">{{ locationLabel(model) }}</td>
        <td>
          <span class="badge" :class="model.running ? 'badge-green' : 'badge-gray'">
            {{ model.running ? 'Running' : 'Pulled' }}
          </span>
        </td>
        <td v-if="auth.isAdmin" style="text-align:right;white-space:nowrap">
          <AppButton v-if="!model.running" size="sm" @click="startModel(model)">Start</AppButton>
          <AppButton v-else size="sm" @click="stopModel(model)">Stop</AppButton>
        </td>
      </tr>
    </DataTable>

    <div v-if="auth.isAdmin" class="card" style="margin-top:24px">
      <h2 style="margin-top:0">Ollama API key</h2>
      <p style="color:var(--text-secondary);font-size:13px">
        Home holds the upstream Ollama key. Clients authenticate with a BarkVisor user or inference token.
        {{ store.settings?.hasApiKey ? 'A key is stored on this Device.' : 'No upstream key stored.' }}
      </p>
      <div class="form-group">
        <input v-model="apiKeyDraft" type="password" placeholder="OLLAMA_API_KEY" />
      </div>
      <AppButton variant="primary" :loading="keySaving" loading-text="Saving..." @click="saveKey">
        Save Ollama key
      </AppButton>
    </div>
  </template>
</template>
