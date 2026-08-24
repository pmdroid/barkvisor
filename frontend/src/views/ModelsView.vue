<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { OllamaCatalogModel, OllamaTaskAccepted } from '../api/types'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppModal from '../components/ui/AppModal.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import ProgressBar from '../components/ui/ProgressBar.vue'
import { useTaskPoller } from '../composables/useTaskPoller'
import { useAuthStore } from '../stores/auth'
import { useOllamaStore } from '../stores/ollama'
import { useToastStore } from '../stores/toast'
import { formatBytes } from '../utils/format'
import { useDevicesStore } from '../stores/devices'
import { ollamaModelMatchesName, ollamaPullPercent, ollamaPullTaskPath, ollamaRunningHostId, ollamaStartBody } from '../utils/ollamaTask'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'

const auth = useAuthStore()
const store = useOllamaStore()
const devices = useDevicesStore()
const toast = useToastStore()
const poller = useTaskPoller()
const pullName = ref('')
const pullHost = ref('')
const pulling = ref(false)
const cancelling = ref(false)
const pullTask = ref<OllamaTaskAccepted | null>(null)
const cancelledByUser = ref(false)
const apiKeyDraft = ref('')
const keySaving = ref(false)
const nameQuery = ref('')
const startTarget = ref<OllamaCatalogModel | null>(null)
const startHost = ref('')
const starting = ref(false)
const stopTarget = ref<OllamaCatalogModel | null>(null)
const stopping = ref(false)

const hostOptions = computed(() =>
  store.devices
    .filter((row) => row.reachable)
    .map((row) => ({
      value: row.hostId,
      label: row.displayName?.trim() || row.hostId,
    })),
)

const filteredModels = computed(() =>
  store.models.filter((row) => ollamaModelMatchesName(row.name, nameQuery.value)),
)

const pullPercent = computed(() => ollamaPullPercent(poller.task.value?.progress))
const pullIndeterminate = computed(() => pullPercent.value == null)
const pullProgressLabel = computed(() => {
  const progress = pullPercent.value
  if (progress == null) return 'Pulling…'
  return `Pulling ${progress}%`
})

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

function pullPath(task: OllamaTaskAccepted): string {
  return ollamaPullTaskPath(task, devices.selfDevice?.hostId)
}

async function pullModel() {
  const name = pullName.value.trim()
  if (!name) return
  pulling.value = true
  cancelledByUser.value = false
  try {
    const task = await store.pull(name, pullHost.value || undefined)
    pullTask.value = task
    const event = await poller.poll(task.taskID, {
      path: pullPath(task),
      onComplete: () => {
        toast.success(`Ollama pulled ${name}`)
        void store.fetchCatalog()
      },
      onFailed: (event) => {
        if (event.status === 'cancelled' || cancelledByUser.value) {
          toast.success(`Ollama pull cancelled`)
        } else {
          toast.error(event.error || `Ollama could not pull ${name}`)
        }
      },
    })
    if (event.status === 'completed') pullName.value = ''
  } catch (e: unknown) {
    if (cancelledByUser.value) {
      toast.success('Ollama pull cancelled')
    } else {
      toast.error(apiErrorMessage(e))
    }
  } finally {
    pulling.value = false
    pullTask.value = null
  }
}

async function cancelPull() {
  const task = pullTask.value
  if (!task) return
  cancelledByUser.value = true
  cancelling.value = true
  try {
    await api.delete(pullPath(task))
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    poller.stop()
    cancelling.value = false
  }
}

function requestStart(model: OllamaCatalogModel) {
  startTarget.value = model
  startHost.value = ''
}

function requestStop(model: OllamaCatalogModel) {
  stopTarget.value = model
}

async function startModel() {
  const model = startTarget.value
  if (!model) return
  starting.value = true
  try {
    const body = ollamaStartBody(model.name, startHost.value || undefined)
    await store.start(body.name, body.hostId)
    toast.success(`Ollama loaded ${model.name}`)
    startTarget.value = null
    await store.fetchCatalog()
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    starting.value = false
  }
}

async function stopModel() {
  const name = stopTarget.value?.name
  if (!name) return
  const live = store.models.find((row) => row.name === name)
  const hostId = ollamaRunningHostId(live)
  if (!hostId) {
    stopTarget.value = null
    toast.error(`Ollama is not running ${name}`)
    return
  }
  stopping.value = true
  try {
    await store.stop(name, hostId)
    toast.success(`Ollama unloaded ${name}`)
    stopTarget.value = null
    await store.fetchCatalog()
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    stopping.value = false
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
          <AppButton variant="primary" :disabled="!pullName.trim() || pulling" :loading="pulling && !cancelling" loading-text="Pulling..." @click="pullModel">
            Pull
          </AppButton>
          <AppButton v-if="pulling" variant="ghost" :loading="cancelling" loading-text="Cancelling..." @click="cancelPull">
            Cancel
          </AppButton>
        </div>
        <div v-if="pulling" style="margin-top:10px">
          <ProgressBar
            :percent="pullPercent"
            :indeterminate="pullIndeterminate"
            :label="pullProgressLabel"
          />
        </div>
      </div>
    </div>

    <EmptyState
      v-if="store.models.length === 0 && !store.loading"
      icon="monitor"
      title="No Ollama models yet"
      subtitle="Pull a model to open Chat. Completions go through /v1/chat/completions."
    />

    <template v-else>
      <div class="form-group" style="margin-bottom:12px">
        <input v-model="nameQuery" placeholder="Search models..." style="width:100%;max-width:360px" />
      </div>

      <EmptyState
        v-if="filteredModels.length === 0 && !store.loading"
        icon="monitor"
        title="No matching models"
        subtitle="Try a different name."
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
        <tr v-for="model in filteredModels" :key="model.name">
          <td style="font-weight:500">{{ model.name }}</td>
          <td style="color:var(--text-secondary)">{{ model.size ? formatBytes(model.size) : '—' }}</td>
          <td style="color:var(--text-secondary)">{{ locationLabel(model) }}</td>
          <td>
            <span class="badge" :class="model.running ? 'badge-green' : 'badge-gray'">
              {{ model.running ? 'Running' : 'Pulled' }}
            </span>
          </td>
          <td v-if="auth.isAdmin" style="text-align:right;white-space:nowrap">
            <AppButton v-if="!model.running" size="sm" @click="requestStart(model)">Start</AppButton>
            <AppButton v-else size="sm" @click="requestStop(model)">Stop</AppButton>
          </td>
        </tr>
      </DataTable>
    </template>

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

  <AppModal v-if="startTarget" :title="`Start ${startTarget.name}`" @close="!starting && (startTarget = null)">
    <div class="form-group" style="margin:0">
      <select v-model="startHost" style="min-width:160px">
        <option value="">Any reachable {{ DEVICE_LABEL }}</option>
        <option v-for="opt in hostOptions" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
      </select>
    </div>
    <template #actions>
      <AppButton variant="ghost" :disabled="starting" @click="startTarget = null">Cancel</AppButton>
      <AppButton variant="primary" :loading="starting" loading-text="Starting..." @click="startModel">Start</AppButton>
    </template>
  </AppModal>

  <ConfirmDialog
    v-if="stopTarget"
    title="Stop model"
    :message="`Stop ${stopTarget.name} on the ${DEVICE_LABEL} that is running it?`"
    confirm-label="Stop"
    danger
    :loading="stopping"
    @confirm="stopModel"
    @cancel="stopTarget = null"
  />
</template>
