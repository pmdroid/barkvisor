<script setup lang="ts">
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { Line } from 'vue-chartjs'
import {
  Chart as ChartJS,
  CategoryScale,
  LinearScale,
  PointElement,
  LineElement,
  Filler,
} from 'chart.js'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type {
  APIKeyCreateResponse,
  APIKeyResponse,
  HostGPUDevice,
  OllamaCatalogModel,
  OllamaTaskAccepted,
  RemoteAccessStatus,
  SystemStatsSample,
} from '../api/types'
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
import {
  emptyDeviceStatsChartSeries,
  mapStatsHistorySamples,
} from '../utils/deviceStatsHistory'
import { formatBytes } from '../utils/format'
import { deviceGpuDevicesPath, deviceStatsHistoryPath } from '../utils/homeDeviceApi'
import { useDevicesStore } from '../stores/devices'
import {
  defaultOllamaStatsHostId,
  ollamaGpuEmptyCopy,
  ollamaGpuOccupancyLines,
  ollamaStatsApiTarget,
  ollamaStatsUnreachableCopy,
  shouldFetchOllamaDeviceStats,
} from '../utils/ollamaDeviceStats'
import { downloadOllamaPsExport } from '../utils/ollamaPsExport'
import { ollamaSettingsKeyBody } from '../utils/ollamaSettings'
import { ollamaModelMatchesName, ollamaPullPercent, ollamaPullTaskPath, ollamaRunningHostId, ollamaStartBody } from '../utils/ollamaTask'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'
import { inferenceHowToFromOrigin, tailnetListenHost } from '../utils/inferenceApiHowTo'
import {
  inferenceHowToMintBanner,
  inferenceHowToMintBody,
  needsInferenceHowToMint,
} from '../utils/inferenceHowToMint'

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Filler)

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
const keyHost = ref('')
const keySaving = ref(false)
const nameQuery = ref('')
const startTarget = ref<OllamaCatalogModel | null>(null)
const startHost = ref('')
const starting = ref(false)
const stopTarget = ref<OllamaCatalogModel | null>(null)
const stopping = ref(false)
const copied = ref('')
const remoteAccess = ref<RemoteAccessStatus | null>(null)
const mintedKey = ref('')
const mintBanner = ref('')
let mintAttempted = false
const statsHost = ref('')
const hostGPUs = ref<HostGPUDevice[] | null>(null)
const history = reactive(emptyDeviceStatsChartSeries())

const howTo = computed(() =>
  inferenceHowToFromOrigin(window.location.origin, {
    role: 'self',
    advertiseHost: remoteAccess.value?.advertiseUrl,
    tailnetHost: tailnetListenHost(remoteAccess.value?.tailscale),
    grantPlaintext: mintedKey.value || null,
  }),
)

async function copySnippet(key: string, text: string) {
  try {
    await navigator.clipboard.writeText(text)
    copied.value = key
    window.setTimeout(() => {
      if (copied.value === key) copied.value = ''
    }, 1500)
  } catch {
    /* ignore */
  }
}

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

const selectedKeyHost = computed(() => keyHost.value || hostOptions.value[0]?.value || '')
const selectedHostSettings = computed(() =>
  selectedKeyHost.value ? store.hostSettings(selectedKeyHost.value) : null,
)
const keyBody = computed(() => ollamaSettingsKeyBody(selectedKeyHost.value, apiKeyDraft.value))

const statsHostOptions = computed(() => {
  const selected = statsHost.value
  return store.devices
    .filter((row) => row.reachable || row.hostId === selected)
    .map((row) => ({
      value: row.hostId,
      label: row.displayName?.trim() || row.hostId,
    }))
})

const selectedCatalogDevice = computed(
  () => store.devices.find((row) => row.hostId === statsHost.value) ?? null,
)

const statsTarget = computed(() =>
  ollamaStatsApiTarget(
    statsHost.value,
    store.devices,
    (id) => devices.deviceByHostId(id),
    devices.selfDevice?.hostId,
  ),
)

const fetchLiveStats = computed(() =>
  shouldFetchOllamaDeviceStats(selectedCatalogDevice.value, statsTarget.value),
)

const gpuEmptyCopy = computed(() => ollamaGpuEmptyCopy(hostGPUs.value))

function resetHistory() {
  const empty = emptyDeviceStatsChartSeries()
  history.labels = empty.labels
  history.cpu = empty.cpu
  history.memoryGB = empty.memoryGB
  history.memoryTotalGB = empty.memoryTotalGB
}

function applyHistory(series: ReturnType<typeof mapStatsHistorySamples>) {
  history.labels = series.labels
  history.cpu = series.cpu
  history.memoryGB = series.memoryGB
  history.memoryTotalGB = series.memoryTotalGB
}

function makeSparkOpts(max?: number) {
  return {
    responsive: true,
    maintainAspectRatio: false,
    animation: false as const,
    scales: {
      x: { display: false },
      y: { display: false, beginAtZero: true, max },
    },
    plugins: { tooltip: { enabled: false }, legend: { display: false } },
    elements: {
      point: { radius: 0 },
      line: { tension: 0.4, borderWidth: 1.5 },
    },
  }
}

const cpuSparkOpts = computed(() => makeSparkOpts(100))
const memSparkOpts = computed(() =>
  makeSparkOpts(history.memoryTotalGB != null ? Math.ceil(history.memoryTotalGB) : undefined),
)

const cpuSparkData = computed(() => ({
  labels: history.labels,
  datasets: [{
    data: history.cpu,
    borderColor: 'rgba(0,144,248,0.5)',
    backgroundColor: 'rgba(0,144,248,0.06)',
    fill: true,
  }],
}))

const memSparkData = computed(() => ({
  labels: history.labels,
  datasets: [{
    data: history.memoryGB,
    borderColor: 'rgba(52,211,153,0.5)',
    backgroundColor: 'rgba(52,211,153,0.06)',
    fill: true,
  }],
}))

const latestCpu = computed(() => {
  if (!fetchLiveStats.value) return null
  if (history.cpu.length) return history.cpu[history.cpu.length - 1]
  return devices.deviceByHostId(statsHost.value)?.resources?.cpuLoadPercent ?? null
})
const latestMemoryGB = computed(() => {
  if (!fetchLiveStats.value) return null
  if (history.memoryGB.length) return history.memoryGB[history.memoryGB.length - 1]
  const used = devices.deviceByHostId(statsHost.value)?.resources?.memoryUsedMB
  return used != null ? used / 1024 : null
})
const memoryTotalGB = computed(() => {
  if (history.memoryTotalGB != null) return history.memoryTotalGB
  const total = devices.deviceByHostId(statsHost.value)?.resources?.memoryTotalMB
  return total != null ? total / 1024 : null
})

let statsSeq = 0

async function refreshLiveStats() {
  const host = statsHost.value
  const target = statsTarget.value
  const seq = ++statsSeq
  if (!host || !fetchLiveStats.value || !target) {
    if (seq !== statsSeq) return
    resetHistory()
    hostGPUs.value = null
    return
  }
  try {
    const { data } = await api.get<SystemStatsSample[]>(deviceStatsHistoryPath(target))
    if (seq !== statsSeq || statsHost.value !== host) return
    applyHistory(mapStatsHistorySamples(Array.isArray(data) ? data : []))
  } catch {
    if (seq !== statsSeq || statsHost.value !== host) return
  }
  try {
    const { data } = await api.get<HostGPUDevice[]>(deviceGpuDevicesPath(target))
    if (seq !== statsSeq || statsHost.value !== host) return
    hostGPUs.value = Array.isArray(data) ? data : []
  } catch {
    if (seq !== statsSeq || statsHost.value !== host) return
    hostGPUs.value = []
  }
}

const pullPercent = computed(() => ollamaPullPercent(poller.task.value?.progress))
const pullIndeterminate = computed(() => pullPercent.value == null)
const pullProgressLabel = computed(() => {
  const progress = pullPercent.value
  if (progress == null) return 'Pulling…'
  return `Pulling ${progress}%`
})

let pollTimer: number
let statsTimer: number
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
  if (auth.isAdmin) {
    void store.fetchSettings()
  }
  void loadHowTo()
  pollTimer = window.setInterval(() => { void store.fetchCatalog() }, 10_000)
  statsTimer = window.setInterval(() => { void refreshLiveStats() }, 5_000)
})
onUnmounted(() => {
  clearInterval(pollTimer)
  clearInterval(statsTimer)
})

watch(
  () => [store.models, store.devices] as const,
  () => {
    const current = statsHost.value
    if (!current || !store.devices.some((row) => row.hostId === current)) {
      statsHost.value = defaultOllamaStatsHostId(store.models, store.devices)
    }
  },
  { immediate: true, deep: true },
)

watch(
  () => [statsHost.value, fetchLiveStats.value] as const,
  () => {
    resetHistory()
    hostGPUs.value = null
    void refreshLiveStats()
  },
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

function onKeyHost(event: Event) {
  const target = event.target as HTMLSelectElement
  keyHost.value = target.value
}

function exportPs() {
  downloadOllamaPsExport(store.models)
}

async function loadHowTo() {
  try {
    const { data } = await api.get<RemoteAccessStatus>('/system/remote-access')
    remoteAccess.value = data
  } catch {
    /* LAN origin fallback */
  }
  await mintHowToKeyIfNeeded()
}

async function mintHowToKeyIfNeeded() {
  if (mintAttempted) return
  mintAttempted = true
  try {
    const { data: keys } = await api.get<APIKeyResponse[]>('/auth/keys')
    if (!needsInferenceHowToMint(keys)) return
    const { data } = await api.post<APIKeyCreateResponse>('/auth/keys', inferenceHowToMintBody())
    mintedKey.value = data.key
  } catch (e: unknown) {
    mintBanner.value = inferenceHowToMintBanner({
      status: axiosStatus(e),
      message: apiErrorMessage(e),
    })
  }
}

function axiosStatus(error: unknown): number | null {
  if (typeof error === 'object' && error !== null && 'response' in error) {
    const status = (error as { response?: { status?: number } }).response?.status
    return typeof status === 'number' ? status : null
  }
  return null
}

async function saveKey() {
  const body = keyBody.value
  if (!body) return
  keySaving.value = true
  try {
    await store.saveSettings(body)
    apiKeyDraft.value = ''
    toast.success('Ollama API key saved')
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

  <div class="card" style="margin-bottom:16px">
    <h2 style="margin-top:0">Use this API</h2>
    <p style="color:var(--text-secondary);font-size:13px">
      OpenAI-compatible completions on this {{ HOME_LABEL }}:
      <code>{{ howTo.lanCompletionsURL }}</code>.
      Send <code>Authorization: Bearer</code> with an inference key.
      That is not Device :11434.
    </p>
    <p v-if="mintBanner" style="color:var(--danger, #b42318);font-size:13px">{{ mintBanner }}</p>
    <div class="form-group">
      <label>curl</label>
      <pre class="howto-pre">{{ howTo.curl }}</pre>
      <AppButton size="sm" @click="copySnippet('curl', howTo.curl)">
        {{ copied === 'curl' ? 'Copied' : 'Copy curl' }}
      </AppButton>
    </div>
    <div class="form-group">
      <label>OPENAI_BASE_URL / OPENAI_API_KEY</label>
      <pre class="howto-pre">{{ howTo.env }}</pre>
      <AppButton size="sm" @click="copySnippet('env', howTo.env)">
        {{ copied === 'env' ? 'Copied' : 'Copy env' }}
      </AppButton>
    </div>
    <div v-if="mintedKey" class="form-group">
      <label>API key (shown once)</label>
      <pre class="howto-pre">{{ mintedKey }}</pre>
      <AppButton size="sm" @click="copySnippet('key', mintedKey)">
        {{ copied === 'key' ? 'Copied' : 'Copy key' }}
      </AppButton>
    </div>
    <h3>From inside a Workload</h3>
    <p style="color:var(--text-secondary);font-size:13px">
      Cage <code>OPENAI_BASE_URL</code> is <code>{{ howTo.cageBaseURL }}</code>
      (<code>CAGE_OPENAI_BASE_URL</code>, PAS-268 guestfwd). {{ howTo.cageDnsLine }}
      This is not the LAN :7777 URL.
    </p>
    <div class="form-group" style="margin-bottom:0">
      <pre class="howto-pre">{{ howTo.cageEnv }}</pre>
      <AppButton size="sm" @click="copySnippet('cage', howTo.cageEnv)">
        {{ copied === 'cage' ? 'Copied' : 'Copy cage env' }}
      </AppButton>
    </div>
  </div>

  <EmptyState
    v-if="!store.anyReachable && !store.loading"
    icon="monitor"
    title="Ollama is not reachable"
    :subtitle="store.devices[0]?.installHint || 'Install Ollama on a Device to manage models here.'"
  />

  <template v-else>
    <div class="card" style="margin-bottom:16px">
      <div class="form-group" style="margin:0 0 12px">
        <label>{{ DEVICE_LABEL }}</label>
        <select v-model="statsHost" style="min-width:160px">
          <option v-for="opt in statsHostOptions" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
        </select>
      </div>

      <template v-if="!fetchLiveStats">
        <p class="stats-unknown">{{ ollamaStatsUnreachableCopy() }}</p>
        <p class="stats-unknown">CPU unknown · Memory unknown · GPU unknown</p>
      </template>

      <template v-else>
        <div class="stat-grid">
          <div class="dash-stat" style="border-left: 3px solid var(--accent)">
            <div class="dash-stat-spark" v-if="history.cpu.length > 1">
              <Line :data="cpuSparkData" :options="cpuSparkOpts" />
            </div>
            <div class="dash-stat-content">
              <div class="dash-stat-top">
                <span class="dash-stat-number">{{ latestCpu == null ? '—' : latestCpu.toFixed(0) + '%' }}</span>
                <span class="dash-stat-trend up">device</span>
              </div>
              <div class="dash-stat-label">CPU</div>
            </div>
          </div>
          <div class="dash-stat" style="border-left: 3px solid var(--green)">
            <div class="dash-stat-spark" v-if="history.memoryGB.length > 1">
              <Line :data="memSparkData" :options="memSparkOpts" />
            </div>
            <div class="dash-stat-content">
              <div class="dash-stat-top">
                <span class="dash-stat-number">
                  <template v-if="latestMemoryGB == null">—</template>
                  <template v-else>{{ latestMemoryGB.toFixed(1) }} <small>GB</small></template>
                </span>
                <span v-if="memoryTotalGB != null" class="dash-stat-trend up">/ {{ memoryTotalGB.toFixed(0) }} GB</span>
              </div>
              <div class="dash-stat-label">Memory</div>
            </div>
          </div>
        </div>

        <div v-if="gpuEmptyCopy || (hostGPUs && hostGPUs.length)" class="gpu-card">
          <div class="gpu-card-title">GPU</div>
          <p v-if="gpuEmptyCopy" class="gpu-card-status">{{ gpuEmptyCopy }}</p>
          <ul v-else-if="hostGPUs && hostGPUs.length" class="gpu-list">
            <li v-for="gpu in hostGPUs" :key="gpu.pciAddress">
              <span v-for="line in ollamaGpuOccupancyLines(gpu)" :key="line" class="gpu-meta">{{ line }}</span>
            </li>
          </ul>
        </div>
      </template>
    </div>

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
      subtitle="Pull a model. Completions go through /v1/chat/completions. Chat/Agents: Library Onyx."
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
        Home holds upstream keys per {{ DEVICE_LABEL }}. Clients authenticate with a BarkVisor user or inference token.
        {{
          selectedHostSettings?.hasApiKey
            ? `A key is stored for this ${DEVICE_LABEL}.`
            : `No upstream key stored for this ${DEVICE_LABEL}.`
        }}
      </p>
      <div class="form-group">
        <label>{{ DEVICE_LABEL }}</label>
        <select
          :value="selectedKeyHost"
          style="min-width:160px"
          :disabled="hostOptions.length === 0"
          @change="onKeyHost"
        >
          <option v-for="opt in hostOptions" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
        </select>
      </div>
      <div class="form-group">
        <input v-model="apiKeyDraft" type="password" placeholder="OLLAMA_API_KEY" :disabled="!selectedKeyHost" />
      </div>
      <AppButton variant="primary" :disabled="!keyBody" :loading="keySaving" loading-text="Saving..." @click="saveKey">
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

<style scoped>
.howto-pre {
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
  cursor: pointer;
  color: var(--text-secondary);
  font-size: 13px;
  font-weight: 600;
  padding: 6px 10px;
  border: 1px solid var(--border);
  border-radius: var(--radius-xs);
  background: var(--bg-card);
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
.stat-grid {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 16px;
  margin-bottom: 16px;
}
.dash-stat {
  position: relative;
  background: var(--bg);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  overflow: hidden;
  min-height: 120px;
}
.dash-stat-spark {
  position: absolute;
  inset: 0;
  pointer-events: none;
  opacity: 0.7;
}
.dash-stat-spark canvas {
  width: 100% !important;
  height: 100% !important;
}
.dash-stat-content {
  position: relative;
  z-index: 1;
  padding: 16px;
}
.dash-stat-top {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  margin-bottom: 12px;
}
.dash-stat-number {
  font-size: 32px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
  letter-spacing: -0.03em;
  line-height: 1;
}
.dash-stat-number small {
  font-size: 16px;
  font-weight: 500;
  color: var(--text-secondary);
}
.dash-stat-trend {
  font-size: 11px;
  font-weight: 600;
  color: var(--text-dim);
  padding: 3px 8px;
  border-radius: 2px;
}
.dash-stat-trend.up {
  color: var(--green);
  background: var(--green-muted);
}
.dash-stat-label {
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
}
.gpu-card {
  padding: 12px 0 0;
}
.gpu-card-title {
  font-size: 13px;
  font-weight: 600;
}
.gpu-card-status {
  margin: 6px 0 0;
  font-size: 13px;
  color: var(--text-secondary);
}
.gpu-list {
  list-style: none;
  margin: 8px 0 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.gpu-list li {
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.gpu-meta {
  font-size: 12px;
  color: var(--text-secondary);
}
.gpu-list li .gpu-meta:first-child {
  color: var(--text);
  font-weight: 600;
  font-size: 13px;
}
@media (max-width: 720px) {
  .stat-grid {
    grid-template-columns: 1fr;
  }
}
</style>
