<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type {
  OllamaCatalogModel,
  OllamaTaskAccepted,
  RemoteAccessStatus,
} from '../api/types'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
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
import { useDeviceScopeStore } from '../stores/deviceScope'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { canCallDeviceAPI, isSelfDevice } from '../utils/homeDeviceApi'
import {
  ollamaInstallOsLabel,
  ollamaInstallOses,
  ollamaInstallSteps,
} from '../utils/ollamaInstall'
import { downloadOllamaPsExport } from '../utils/ollamaPsExport'
import {
  ollamaDefaultStartHostId,
  ollamaModelMatchesName,
  ollamaPullPercent,
  ollamaPullTaskPath,
  ollamaRunningHostId,
  ollamaSoleStartHostId,
  ollamaStartBody,
  ollamaStartCanStart,
  ollamaStartDisabledReason,
  ollamaStartNeedsPicker,
  ollamaStartReachableCandidates,
} from '../utils/ollamaTask'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'
import { scopeOllamaModels, scopeRows } from '../utils/deviceScope'
import { inferenceHowToFromOrigin, tailnetListenHost } from '../utils/inferenceApiHowTo'

const auth = useAuthStore()
const store = useOllamaStore()
const devices = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const toast = useToastStore()
const poller = useTaskPoller()
const pullName = ref('')
const pulling = ref(false)
const cancelling = ref(false)
const pullTask = ref<OllamaTaskAccepted | null>(null)
const cancelledByUser = ref(false)
const nameQuery = ref('')
const startTarget = ref<OllamaCatalogModel | null>(null)
const startHost = ref('')
const starting = ref(false)
const stopTarget = ref<OllamaCatalogModel | null>(null)
const stopping = ref(false)
const copied = ref('')
const remoteAccess = ref<RemoteAccessStatus | null>(null)
const rechecking = ref(false)

const howTo = computed(() =>
  inferenceHowToFromOrigin(window.location.origin, {
    role: 'self',
    advertiseHost: remoteAccess.value?.advertiseUrl,
    tailnetHost: tailnetListenHost(remoteAccess.value?.tailscale),
  }),
)

const selectedHostId = ref('')

watch(
  () => devices.selfDevice?.hostId,
  (id) => {
    if (!selectedHostId.value && id) selectedHostId.value = id
  },
  { immediate: true },
)

watch(
  () => devices.devices,
  (list) => {
    if (!list.length) return
    if (!list.some((device) => device.hostId === selectedHostId.value)) {
      selectedHostId.value = devices.selfDevice?.hostId || list[0]?.hostId || ''
    }
  },
)

const pickerRows = computed(() => {
  if (devices.devices.length === 0) {
    const selfId = devices.selfDevice?.hostId || ''
    return [{
      hostId: selfId,
      name: `This ${DEVICE_LABEL}`,
      isSelf: true,
      deviceReachable: true,
      platform: '',
      ollama: store.devices.find((row) => row.hostId === selfId) ?? store.devices[0] ?? null,
    }]
  }
  return devices.devices.map((device) => ({
    hostId: device.hostId,
    name: deviceDisplayLabel(device),
    isSelf: isSelfDevice(device),
    deviceReachable: canCallDeviceAPI(device),
    platform: device.platform
      ? [device.platform.os, device.platform.arch].filter(Boolean).join(' · ')
      : '',
    ollama: store.devices.find((row) => row.hostId === device.hostId) ?? null,
  }))
})

const selectedRow = computed(() =>
  pickerRows.value.find((row) => row.hostId === selectedHostId.value) ?? pickerRows.value[0] ?? null,
)

const selectedName = computed(() => selectedRow.value?.name || `This ${DEVICE_LABEL}`)

function modelCountFor(hostId: string): number {
  return store.models.filter((model) => model.locations.some((loc) => loc.hostId === hostId)).length
}

function pickerState(row: (typeof pickerRows.value)[number]): { label: string; cls: string } {
  if (!row.deviceReachable) return { label: 'Unreachable', cls: 'bad' }
  if (row.ollama?.reachable) {
    const count = modelCountFor(row.hostId)
    return { label: count ? `${count} model${count === 1 ? '' : 's'}` : 'Ollama up', cls: 'ok' }
  }
  return { label: 'No Ollama', cls: '' }
}

function pickerDot(row: (typeof pickerRows.value)[number]): string {
  if (!row.deviceReachable) return 'off'
  return row.ollama?.reachable ? 'ok' : 'warn'
}

function selectDevice(hostId: string) {
  selectedHostId.value = hostId
}

const selectedDeviceReachable = computed(() => selectedRow.value?.deviceReachable ?? true)
const selectedOllamaReachable = computed(() => Boolean(selectedRow.value?.ollama?.reachable))

const showSelectedInstall = computed(() =>
  selectedDeviceReachable.value && !selectedOllamaReachable.value && !store.loading,
)

const showSelectedCatalog = computed(() =>
  selectedOllamaReachable.value
  || (!store.loading && store.catalog != null && !showSelectedInstall.value),
)

const selectedChip = computed(() => {
  if (!selectedDeviceReachable.value) return { label: 'Unreachable', cls: 'red' }
  if (selectedOllamaReachable.value) return { label: 'Ollama up', cls: 'green' }
  return { label: 'No Ollama', cls: '' }
})

const selectedInstallSteps = computed(() => {
  const device = devices.devices.find((row) => row.hostId === selectedRow.value?.hostId)
  const platformOs = device?.platform?.os ?? devices.selfDevice?.platform?.os ?? null
  const hint = selectedRow.value?.ollama?.installHint ?? ''
  return ollamaInstallOses({
    installHints: hint ? [hint] : [],
    platformOs,
  }).map((os) => ({
    os,
    label: ollamaInstallOsLabel(os),
    steps: ollamaInstallSteps(os),
  }))
})

async function recheckOllama() {
  if (rechecking.value) return
  rechecking.value = true
  try {
    await store.fetchCatalog()
  } finally {
    rechecking.value = false
  }
}

async function copySnippet(key: string, text: string) {
  try {
    await navigator.clipboard.writeText(text)
    copied.value = key
    window.setTimeout(() => {
      if (copied.value === key) copied.value = ''
    }, 1500)
  } catch {
  }
}

const hostOptions = computed(() =>
  scopeRows(store.devices, deviceScope.selectedHostId)
    .filter((row) => row.reachable)
    .map((row) => ({
      value: row.hostId,
      label: row.displayName?.trim() || row.hostId,
    })),
)

const pullHost = computed(() => {
  const valid = new Set(hostOptions.value.map((opt) => opt.value))
  return valid.has(selectedHostId.value) ? selectedHostId.value : ''
})

const startHostOptions = computed(() =>
  ollamaStartReachableCandidates(startTarget.value, deviceScope.selectedHostId).map((loc) => {
    const name = loc.displayName?.trim() || loc.hostId
    return {
      value: loc.hostId,
      label: name,
      disabled: false,
    }
  }),
)

const startHostIsCandidate = computed(() =>
  startHostOptions.value.some((opt) => opt.value === startHost.value),
)

watch(startHostOptions, (opts) => {
  if (!startTarget.value) return
  if (!opts.some((opt) => opt.value === startHost.value)) {
    startHost.value = opts[0]?.value ?? ''
  }
})

const filteredModels = computed(() =>
  scopeOllamaModels(
    store.models.filter((row) => ollamaModelMatchesName(row.name, nameQuery.value)),
    deviceScope.selectedHostId,
  ),
)

const scopedModels = computed(() => {
  const row = selectedRow.value
  if (!row || devices.devices.length === 0) return filteredModels.value
  return filteredModels.value.filter((model) =>
    model.locations.some((loc) => loc.hostId === row.hostId),
  )
})

const pullPercent = computed(() => ollamaPullPercent(poller.task.value?.progress))
const pullIndeterminate = computed(() => pullPercent.value == null)
const pullProgressLabel = computed(() => {
  const progress = pullPercent.value
  if (progress == null) return 'Pulling…'
  return `Pulling ${progress}%`
})

let pollTimer: number
async function fetchRemoteAccess() {
  try {
    const { data } = await api.get<RemoteAccessStatus>('/system/remote-access')
    remoteAccess.value = data
  } catch {
    remoteAccess.value = null
  }
}

onMounted(() => {
  void store.fetchCatalog()
  void fetchRemoteAccess()
  void devices.fetchHealth()
  pollTimer = window.setInterval(() => { void store.fetchCatalog() }, 10_000)
})
onUnmounted(() => {
  clearInterval(pollTimer)
})

watch(
  () => [store.models, store.devices, deviceScope.selectedHostId] as const,
  () => {
    const valid = new Set(hostOptions.value.map((opt) => opt.value))
    const scopedHost = !deviceScope.isAll && valid.has(deviceScope.selectedHostId)
      ? deviceScope.selectedHostId
      : ''
    if (startHost.value && !valid.has(startHost.value)) startHost.value = scopedHost
  },
  { immediate: true, deep: true },
)

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
  if (!name || !pullHost.value) return
  pulling.value = true
  cancelledByUser.value = false
  try {
    const task = await store.pull(name, pullHost.value)
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
    if (event.status === 'completed' && pullName.value.trim() === name) pullName.value = ''
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
  if (starting.value) return
  const scope = deviceScope.selectedHostId
  if (!ollamaStartCanStart(model, scope)) return
  if (ollamaStartNeedsPicker(model, scope)) {
    startTarget.value = model
    startHost.value = ollamaDefaultStartHostId(model, scope) ?? ''
    return
  }
  void startModelAt(model, ollamaSoleStartHostId(model, scope))
}

function requestStop(model: OllamaCatalogModel) {
  stopTarget.value = model
}

async function startModelAt(model: OllamaCatalogModel, hostId?: string) {
  starting.value = true
  try {
    const body = ollamaStartBody(model.name, hostId)
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

async function startModel() {
  const model = startTarget.value
  if (!model) return
  if (!startHostIsCandidate.value) {
    toast.error(ollamaStartDisabledReason(model, deviceScope.selectedHostId) ?? 'Pick a Device that has this model')
    return
  }
  await startModelAt(model, startHost.value)
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

function exportPs() {
  downloadOllamaPsExport(store.models)
}
</script>

<template>
  <div class="ops-page">
  <div class="ops-toolbar">
    <h1>Ollama</h1>
    <span class="ops-sub">Models on this {{ HOME_LABEL }}. Completions go to the Device that already has the model.</span>
    <div class="ops-actions">
      <details v-if="store.anyReachable" class="overflow-menu">
        <summary>More</summary>
        <div class="overflow-menu-panel">
          <button
            type="button"
            :disabled="store.models.length === 0"
            @click="exportPs"
          >
            Export JSON
          </button>
        </div>
      </details>
    </div>
  </div>
  <div class="ops-body split">

  <section class="list-col">
    <div class="list-head">{{ DEVICE_LABEL }}s</div>
    <div class="picker-list">
      <button
        v-for="row in pickerRows"
        :key="row.hostId || 'self'"
        type="button"
        class="pick"
        :class="{ selected: selectedRow?.hostId === row.hostId, dimd: !row.deviceReachable && selectedRow?.hostId !== row.hostId, bad: !row.deviceReachable && selectedRow?.hostId === row.hostId }"
        @click="selectDevice(row.hostId)"
      >
        <span class="pick-top">
          <span class="ops-dot" :class="pickerDot(row)"></span>
          <span class="pick-name">{{ row.name }}</span>
          <span v-if="row.isSelf" class="pick-tag">This {{ DEVICE_LABEL }}</span>
          <span class="pick-state" :class="pickerState(row).cls">{{ pickerState(row).label }}</span>
        </span>
        <span class="pick-meta">{{ row.platform || row.ollama?.installHint || '' }}</span>
      </button>
    </div>
  </section>

  <section class="inspect">
  <div class="install-head">
    <h2>{{ selectedName }}</h2>
    <span class="chip" :class="selectedChip.cls">{{ selectedChip.label }}</span>
    <span class="spacer"></span>
    <AppButton size="sm" :loading="rechecking" loading-text="Checking..." @click="recheckOllama">
      Recheck
    </AppButton>
  </div>

  <div class="card" style="margin-bottom:16px">
    <div class="form-group" style="margin:0">
      <label>Completions</label>
      <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
        <code class="howto-pre" style="flex:1;margin:0">{{ howTo.lanCompletionsURL }}</code>
        <AppButton size="sm" @click="copySnippet('completions', howTo.lanCompletionsURL)">
          {{ copied === 'completions' ? 'Copied' : 'Copy' }}
        </AppButton>
      </div>
    </div>
  </div>

  <div v-if="!selectedDeviceReachable" class="sheet fwd-hint">
    Unreachable — Workloads and Ollama on this {{ DEVICE_LABEL }} keep running locally.
  </div>

  <div v-else-if="showSelectedInstall" class="sheet">
    <div class="sheet-head">Install Ollama</div>
    <div v-if="selectedRow?.ollama?.installHint" class="fwd-hint" style="border-bottom:1px solid var(--border-glass)">
      {{ selectedRow.ollama.installHint }}
    </div>
    <template v-for="group in selectedInstallSteps" :key="group.os">
      <div v-for="(step, index) in group.steps" :key="group.os + index" class="step">
        <span class="num">{{ index + 1 }}</span>
        <div class="step-body">
          <div class="step-title">{{ step.title }}<span v-if="selectedInstallSteps.length > 1" class="step-sub" style="display:inline;margin-left:6px">{{ group.label }}</span></div>
          <div v-if="step.command" class="cmd">
            <span>{{ step.command }}</span>
            <AppButton size="sm" @click="copySnippet('install-' + group.os + index, step.command)">
              {{ copied === 'install-' + group.os + index ? 'Copied' : 'Copy' }}
            </AppButton>
          </div>
          <div v-if="step.href" class="cmd">
            <span><a :href="step.href" target="_blank" rel="noopener noreferrer" style="color:var(--accent)">{{ step.href }}</a></span>
            <AppButton size="sm" @click="copySnippet('install-href-' + group.os + index, step.href)">
              {{ copied === 'install-href-' + group.os + index ? 'Copied' : 'Copy' }}
            </AppButton>
          </div>
        </div>
      </div>
    </template>
  </div>

  <template v-else-if="showSelectedCatalog">
    <div v-if="auth.isAdmin" class="card" style="margin-bottom:16px">
      <div class="form-group" style="margin:0">
        <label>Pull by name</label>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <input v-model="pullName" placeholder="llama3" style="flex:1;min-width:160px" />
          <AppButton variant="primary" :disabled="!pullName.trim() || pulling || !pullHost" :loading="pulling && !cancelling" loading-text="Pulling..." @click="pullModel()">
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
      v-if="scopedModels.length === 0 && !store.loading"
      icon="monitor"
      :title="store.models.length === 0 ? 'No Ollama models yet' : nameQuery ? 'No matching models' : `No models on ${selectedName}`"
      :subtitle="nameQuery && store.models.length > 0 ? 'Try a different name.' : 'Pull a model. Completions go through /v1/chat/completions. Chat/Agents: Library Onyx.'"
    />

    <template v-else>
      <div class="form-group" style="margin-bottom:12px">
        <label>Filter catalog</label>
        <input v-model="nameQuery" placeholder="Filter pulled models..." style="width:100%;max-width:360px" />
      </div>

      <DataTable
        :columns="[
          { key: 'name', label: 'Model' },
          { key: 'size', label: 'Size' },
          { key: 'where', label: DEVICE_LABEL },
          { key: 'state', label: 'State' },
          ...(auth.isAdmin ? [{ key: 'actions', label: '', align: 'right' as const }] : []),
        ]"
      >
        <tr v-for="model in scopedModels" :key="model.name">
          <td style="font-weight:500">{{ model.name }}</td>
          <td style="color:var(--text-secondary)">{{ model.size ? formatBytes(model.size) : '—' }}</td>
          <td style="color:var(--text-secondary)">{{ locationLabel(model) }}</td>
          <td>
            <span class="badge" :class="model.running ? 'badge-green' : 'badge-gray'">
              {{ model.running ? 'Running' : 'Pulled' }}
            </span>
          </td>
          <td v-if="auth.isAdmin" style="text-align:right;white-space:nowrap">
            <AppButton
              v-if="!model.running"
              size="sm"
              :disabled="starting || !ollamaStartCanStart(model, deviceScope.selectedHostId)"
              :title="ollamaStartDisabledReason(model, deviceScope.selectedHostId)"
              @click="requestStart(model)"
            >Start</AppButton>
            <AppButton v-else size="sm" @click="requestStop(model)">Stop</AppButton>
          </td>
        </tr>
      </DataTable>
    </template>

  </template>
  </section>

  <AppModal v-if="startTarget" :title="`Start ${startTarget.name}`" @close="!starting && (startTarget = null)">
    <div class="form-group" style="margin:0">
      <AppSelect v-model="startHost" style="min-width:160px" :options="startHostOptions" />
    </div>
    <template #actions>
      <AppButton variant="ghost" :disabled="starting" @click="startTarget = null">Cancel</AppButton>
      <AppButton
        variant="primary"
        :disabled="!startHostIsCandidate || starting"
        :loading="starting"
        loading-text="Starting..."
        @click="startModel"
      >Start</AppButton>
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
  </div>
  </div>
</template>

<style scoped>
.howto-pre {
  display: block;

  font-family: var(--font-mono);
  font-size: 12px;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius-xs);
  padding: 12px;
  overflow-x: auto;
  white-space: pre-wrap;
  word-break: break-all;
  margin: 6px 0 8px;
}
.overflow-menu {
  position: relative;
}
.overflow-menu summary {
  list-style: none;
  box-sizing: border-box;
  height: var(--control-h);
  display: inline-flex;
  align-items: center;
  cursor: pointer;
  color: var(--text-dim);
  font-size: 12.5px;
  font-weight: 600;
  padding: 0 14px;
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: transparent;
}
.overflow-menu summary::-webkit-details-marker {
  display: none;
}
.overflow-menu-panel {
  position: absolute;
  right: 0;
  top: calc(100% + 6px);
  min-width: 160px;
  background: var(--bg-card);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius-xs);
  box-shadow: var(--shadow);
  z-index: 5;
  padding: 4px;
}
.overflow-menu-panel button {
  display: block;
  width: 100%;
  text-align: left;
  background: none;
  border: 0;
  color: var(--text);
  font-size: 13px;
  padding: 8px 10px;
  cursor: pointer;
  border-radius: var(--radius-xs);
}
.overflow-menu-panel button:disabled {
  color: var(--text-dim);
  cursor: not-allowed;
}
.overflow-menu-panel button:not(:disabled):hover {
  background: var(--bg-hover);
}
.stats-unknown {
  margin: 0;
  color: var(--text-secondary);
  font-size: 13px;
  line-height: 1.5;
}
</style>
