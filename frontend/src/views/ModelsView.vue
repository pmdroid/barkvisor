<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type {
  APIKeyCreateResponse,
  APIKeyResponse,
  OllamaCatalogModel,
  OllamaLibrarySearchResult,
  OllamaTaskAccepted,
  RemoteAccessStatus,
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
import { formatBytes } from '../utils/format'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import {
  ollamaCatalogInstallHint,
  ollamaInstallDevices,
  ollamaInstallOsLabel,
  ollamaInstallOses,
  ollamaInstallSteps,
  shouldShowOllamaInstall,
} from '../utils/ollamaInstall'
import { downloadOllamaPsExport } from '../utils/ollamaPsExport'
import {
  ollamaSettingsBackendBody,
  ollamaSettingsKeyBody,
  parseInferenceBackend,
} from '../utils/ollamaSettings'
import { unslothInstallSteps } from '../utils/unslothInstall'
import {
  ollamaLibraryResultName,
  ollamaLibrarySearchQuery,
} from '../utils/ollamaLibrary'
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
import {
  inferenceHowToMintBanner,
  inferenceHowToMintBody,
  needsInferenceHowToMint,
} from '../utils/inferenceHowToMint'

const auth = useAuthStore()
const store = useOllamaStore()
const devices = useDevicesStore()
const deviceScope = useDeviceScopeStore()
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
const backendDraft = ref('ollama')
const backendSaving = ref(false)
const nameQuery = ref('')
const libraryQuery = ref('')
const libraryResults = ref<OllamaLibrarySearchResult[]>([])
const librarySearched = ref(false)
const librarySearching = ref(false)
const libraryError = ref<string | null>(null)
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
const rechecking = ref(false)

const howTo = computed(() =>
  inferenceHowToFromOrigin(window.location.origin, {
    role: 'self',
    advertiseHost: remoteAccess.value?.advertiseUrl,
    tailnetHost: tailnetListenHost(remoteAccess.value?.tailscale),
    grantPlaintext: mintedKey.value || null,
  }),
)

const showOllamaInstall = computed(() =>
  shouldShowOllamaInstall({
    loading: store.loading,
    catalog: store.catalog,
    anyReachable: store.anyReachable,
    devices: store.devices,
  }),
)

const showOllamaCatalog = computed(
  () => store.anyReachable || (!store.loading && store.catalog != null && !showOllamaInstall.value),
)

const installDevices = computed(() => ollamaInstallDevices(store.devices))

const installOses = computed(() => {
  const platforms = [
    devices.selfDevice?.platform?.os,
    ...installDevices.value.map((row) => devices.deviceByHostId(row.hostId)?.platform?.os),
  ]
  return ollamaInstallOses({
    installHints: installDevices.value.map((row) => row.installHint),
    platformOs: platforms.find((os) => os?.trim()) ?? null,
  })
})

const installHint = computed(() =>
  ollamaCatalogInstallHint(installDevices.value, installOses.value[0] ?? 'macos'),
)

const deviceInstallLines = computed(() =>
  installDevices.value.filter((row) => row.installHint?.trim()),
)

const installStepsByOs = computed(() =>
  installOses.value.map((os) => ({
    os,
    label: ollamaInstallOsLabel(os),
    steps: ollamaInstallSteps(os),
  })),
)

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
    /* ignore */
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

const pullHostOptions = computed(() =>
  scopeRows(store.devices, deviceScope.selectedHostId)
    .filter((row) => row.reachable)
    .filter((row) => parseInferenceBackend(store.hostSettings(row.hostId)?.backend) === 'ollama')
    .map((row) => ({
      value: row.hostId,
      label: row.displayName?.trim() || row.hostId,
    })),
)

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

const selectedKeyHost = computed(() => keyHost.value || hostOptions.value[0]?.value || '')
const selectedHostSettings = computed(() =>
  selectedKeyHost.value ? store.hostSettings(selectedKeyHost.value) : null,
)
const currentBackend = computed(() => parseInferenceBackend(selectedHostSettings.value?.backend))
const backendBody = computed(() =>
  ollamaSettingsBackendBody(selectedKeyHost.value, backendDraft.value),
)

watch(
  () => [selectedKeyHost.value, selectedHostSettings.value?.backend] as const,
  () => {
    backendDraft.value = currentBackend.value
  },
  { immediate: true },
)

const scopedHostId = computed(() => (deviceScope.isAll ? '' : deviceScope.selectedHostId))
const scopedDevice = computed(
  () =>
    store.devices.find((row) => row.hostId === scopedHostId.value) ??
    null,
)
const scopedBackendIsUnsloth = computed(
  () =>
    !!scopedHostId.value &&
    parseInferenceBackend(store.hostSettings(scopedHostId.value)?.backend) === 'unsloth',
)
const unslothSteps = computed(() => unslothInstallSteps(scopedDevice.value?.installed === true))
const keyBody = computed(() => ollamaSettingsKeyBody(selectedKeyHost.value, apiKeyDraft.value))

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
  if (auth.isAdmin) {
    void store.fetchSettings()
  }
  void loadHowTo()
  pollTimer = window.setInterval(() => { void store.fetchCatalog() }, 10_000)
})
onUnmounted(() => {
  clearInterval(pollTimer)
})

watch(
  () => [store.models, store.devices, deviceScope.selectedHostId] as const,
  () => {
    const valid = new Set(hostOptions.value.map((opt) => opt.value))
    const pullValid = new Set(pullHostOptions.value.map((opt) => opt.value))
    const scopedHost = !deviceScope.isAll && valid.has(deviceScope.selectedHostId)
      ? deviceScope.selectedHostId
      : ''
    if (pullHost.value && !pullValid.has(pullHost.value)) pullHost.value = scopedHost
    if (startHost.value && !valid.has(startHost.value)) startHost.value = scopedHost
    if (keyHost.value && !valid.has(keyHost.value)) {
      keyHost.value = scopedHost || hostOptions.value[0]?.value || ''
    }
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

let librarySearchGen = 0

async function searchLibrary() {
  const q = ollamaLibrarySearchQuery(libraryQuery.value)
  const gen = ++librarySearchGen
  if (!q) {
    if (gen !== librarySearchGen) return
    libraryResults.value = []
    librarySearched.value = false
    libraryError.value = null
    return
  }
  librarySearching.value = true
  libraryError.value = null
  try {
    const data = await store.searchLibrary(q)
    if (gen !== librarySearchGen || !data) return
    libraryResults.value = data.results
    librarySearched.value = true
  } catch (e: unknown) {
    if (gen !== librarySearchGen) return
    libraryResults.value = []
    librarySearched.value = true
    libraryError.value = apiErrorMessage(e, 'Ollama library is unreachable')
  } finally {
    if (gen === librarySearchGen) librarySearching.value = false
  }
}

async function pullModel(nameOverride?: string) {
  const name = (nameOverride ?? pullName.value).trim()
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

async function saveBackend() {
  const body = backendBody.value
  if (!body) return
  backendSaving.value = true
  try {
    await store.saveSettings(body)
    await store.fetchCatalog()
    toast.success('Inference backend saved')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    backendSaving.value = false
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

  <details class="card howto-collapse" style="margin-bottom:16px">
    <summary class="howto-summary">Use this API</summary>
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
  </details>

  <div v-if="showOllamaInstall" class="card ollama-install">
    <h2 style="margin-top:0">Ollama is not reachable</h2>
    <ul v-if="deviceInstallLines.length" class="install-devices">
      <li v-for="row in deviceInstallLines" :key="row.hostId">
        <strong>{{ row.displayName?.trim() || row.hostId }}</strong>
        — {{ row.installHint }}
      </li>
    </ul>
    <p v-else class="install-hint">{{ installHint }}</p>
    <div v-for="group in installStepsByOs" :key="group.os" class="install-os-group">
      <h3 class="install-os">{{ group.label }}</h3>
      <ol class="install-steps">
        <li v-for="(step, index) in group.steps" :key="group.os + index">
          <div>{{ step.title }}</div>
          <div v-if="step.command" class="form-group" style="margin:8px 0 0">
            <pre class="howto-pre">{{ step.command }}</pre>
            <AppButton size="sm" @click="copySnippet('install-' + group.os + index, step.command)">
              {{ copied === 'install-' + group.os + index ? 'Copied' : 'Copy' }}
            </AppButton>
          </div>
          <div v-if="step.href" class="form-group" style="margin:8px 0 0">
            <a class="install-link" :href="step.href" target="_blank" rel="noopener noreferrer">{{ step.href }}</a>
            <AppButton size="sm" @click="copySnippet('install-href-' + group.os + index, step.href)">
              {{ copied === 'install-href-' + group.os + index ? 'Copied' : 'Copy' }}
            </AppButton>
          </div>
        </li>
      </ol>
    </div>
    <AppButton variant="primary" :loading="rechecking" loading-text="Checking..." @click="recheckOllama">
      Recheck
    </AppButton>
  </div>

  <template v-else-if="showOllamaCatalog">
    <div v-if="auth.isAdmin && !scopedBackendIsUnsloth" class="card" style="margin-bottom:16px">
      <div class="form-group" style="margin:0">
        <label>Pull by name</label>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <input v-model="pullName" placeholder="llama3" style="flex:1;min-width:160px" />
          <select v-model="pullHost" style="min-width:160px">
            <option value="">Any reachable {{ DEVICE_LABEL }}</option>
            <option v-for="opt in pullHostOptions" :key="opt.value" :value="opt.value">{{ opt.label }}</option>
          </select>
          <AppButton variant="primary" :disabled="!pullName.trim() || pulling || !store.anyReachable" :loading="pulling && !cancelling" loading-text="Pulling..." @click="pullModel()">
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

    <div v-if="auth.isAdmin && scopedBackendIsUnsloth" class="card" style="margin-bottom:16px">
      <div class="form-group" style="margin:0">
        <label>Unsloth</label>
        <p class="stats-unknown" style="margin:0">
          {{ scopedDevice?.displayName?.trim() || scopedHostId }} serves weights staged on the
          {{ DEVICE_LABEL }}. Pull by name and the Ollama library do not apply here.
        </p>
        <ol class="install-steps" style="margin-top:8px">
          <li v-for="(step, index) in unslothSteps" :key="'unsloth-' + index">
            <div>{{ step.title }}</div>
            <div v-if="step.command" class="form-group" style="margin:8px 0 0">
              <pre class="howto-pre">{{ step.command }}</pre>
              <AppButton size="sm" @click="copySnippet('unsloth-' + index, step.command)">
                {{ copied === 'unsloth-' + index ? 'Copied' : 'Copy' }}
              </AppButton>
            </div>
          </li>
        </ol>
        <AppButton variant="primary" :loading="rechecking" loading-text="Checking..." @click="recheckOllama">
          Recheck
        </AppButton>
      </div>
    </div>

    <div v-if="auth.isAdmin && !scopedBackendIsUnsloth" class="card" style="margin-bottom:16px">
      <div class="form-group" style="margin:0">
        <label>Library search</label>
        <p class="stats-unknown" style="margin:0 0 8px">Search popular models on ollama.com. Catalog filter below only matches models already pulled.</p>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <input
            v-model="libraryQuery"
            placeholder="Search the Ollama library..."
            style="flex:1;min-width:160px"
            @keydown.enter.prevent="searchLibrary"
          />
          <AppButton
            variant="primary"
            :disabled="!ollamaLibrarySearchQuery(libraryQuery) || librarySearching"
            :loading="librarySearching"
            loading-text="Searching..."
            @click="searchLibrary"
          >
            Search
          </AppButton>
        </div>
        <p v-if="!ollamaLibrarySearchQuery(libraryQuery)" class="stats-unknown" style="margin:8px 0 0">
          Enter a name to search the Ollama library.
        </p>
        <p v-else-if="librarySearching" class="stats-unknown" style="margin:8px 0 0">Searching the Ollama library…</p>
        <p v-else-if="libraryError" class="stats-unknown" style="margin:8px 0 0">{{ libraryError }}</p>
        <p v-else-if="librarySearched && libraryResults.length === 0" class="stats-unknown" style="margin:8px 0 0">
          No library matches for “{{ libraryQuery.trim() }}”.
        </p>
        <ul v-else-if="libraryResults.length" class="library-results">
          <li v-for="row in libraryResults" :key="row.name">
            <span>
              <strong>{{ row.name }}</strong>
              <span v-if="row.size" class="stats-unknown"> · {{ formatBytes(row.size) }}</span>
            </span>
            <AppButton
              size="sm"
              :disabled="!ollamaLibraryResultName(row) || pulling || !store.anyReachable"
              @click="pullModel(ollamaLibraryResultName(row))"
            >
              Download
            </AppButton>
          </li>
        </ul>
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
        <label>Filter catalog</label>
        <input v-model="nameQuery" placeholder="Filter pulled models..." style="width:100%;max-width:360px" />
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
        <label>Backend</label>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <select v-model="backendDraft" style="min-width:160px" :disabled="!selectedKeyHost">
            <option value="ollama">Ollama</option>
            <option value="unsloth">Unsloth</option>
          </select>
          <AppButton
            variant="primary"
            :disabled="!backendBody"
            :loading="backendSaving"
            loading-text="Saving..."
            @click="saveBackend"
          >
            Save backend
          </AppButton>
        </div>
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
        <option
          v-for="opt in startHostOptions"
          :key="opt.value"
          :value="opt.value"
          :disabled="opt.disabled"
        >{{ opt.label }}</option>
      </select>
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
</template>

<style scoped>
.howto-collapse {
  padding: 16px 20px;
}
.howto-summary {
  cursor: pointer;
  font-size: 16px;
  font-weight: 600;
  list-style: none;
}
.howto-summary::-webkit-details-marker {
  display: none;
}
.howto-summary::before {
  content: '▸ ';
  font-weight: 500;
  color: var(--text-dim);
}
details.howto-collapse[open] > .howto-summary::before {
  content: '▾ ';
}
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
.install-hint,
.install-devices {
  margin: 0 0 12px;
  color: var(--text-secondary);
  font-size: 13px;
  line-height: 1.5;
}
.install-devices {
  padding-left: 18px;
}
.install-os-group + .install-os-group {
  margin-top: 8px;
}
.install-os {
  margin: 0 0 8px;
  font-size: 13px;
  font-weight: 600;
}
.install-steps {
  margin: 0 0 16px;
  padding-left: 20px;
}
.install-steps li {
  margin-bottom: 12px;
}
.install-link {
  display: inline-block;
  margin: 0 8px 8px 0;
  color: var(--accent);
  font-size: 13px;
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
.library-results {
  list-style: none;
  margin: 12px 0 0;
  padding: 0;
}
.library-results li {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 8px 0;
  border-top: 1px solid var(--border-glass);
}
.stats-unknown {
  margin: 0;
  color: var(--text-secondary);
  font-size: 13px;
  line-height: 1.5;
}
</style>
