<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { MetricSample, VM, WorkloadSpec } from '../api/types'
import { useDevicesStore } from '../stores/devices'
import { useAuthStore } from '../stores/auth'
import { useToastStore } from '../stores/toast'
import { useTaskPoller } from '../composables/useTaskPoller'
import { deviceVmPath, deviceTaskPath, canCallDeviceAPI } from '../utils/homeDeviceApi'
import { appOpenUrl, isApplicationWorkload } from '../utils/workloadKind'
import { parseStartOnBoot, startOnBootLabel } from '../utils/workloadStartOnBoot'
import { isSecretEnvKey, buildEnvSavePayload } from '../utils/appDetail'
import { visibleAppMounts, type ComposeMount } from '../utils/composeMounts'
import { applyAppVolumeChange, appPortEditorRows, parseComposePortSlots, setComposePorts, setComposeEnvironment, isComposePortRow, type ComposeMountDraft, type ComposePortRow } from '../utils/composeEdit'
import AppDetailOverview from '../components/AppDetailOverview.vue'
import AppTerminalSessions from '../components/AppTerminalSessions.vue'
import AppMountList from '../components/AppMountList.vue'
import ComposeLogsPanel from '../components/ComposeLogsPanel.vue'
import FolderPicker from '../components/FolderPicker.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppModal from '../components/ui/AppModal.vue'
import ConfirmDialog from '../components/ConfirmDialog.vue'

const route = useRoute()
const router = useRouter()
const devices = useDevicesStore()
const auth = useAuthStore()
const toast = useToastStore()
const { poll, stop: stopTaskPoll } = useTaskPoller()
const vm = ref<VM | null>(null)
const metrics = ref<MetricSample[]>([])
const error = ref('')
const loading = ref(true)
const busy = ref(false)
const saving = ref(false)
const tab = ref('overview')
const terminalOpened = ref(false)
const tabs = ['overview', 'terminal', 'logs', 'environment', 'volumes']
const vmId = computed(() => String(route.params.id ?? ''))
const hostId = computed(() => String(route.params.hostId ?? ''))
const device = computed(() => hostId.value ? devices.deviceByHostId(hostId.value) : devices.selfDevice)
const base = computed(() => device.value ? deviceVmPath(device.value, vmId.value) : null)
const reachable = computed(() => Boolean(device.value && canCallDeviceAPI(device.value)))
const editable = computed(() => auth.isAdmin && reachable.value && !busy.value)
const openUrl = computed(() => vm.value && reachable.value ? appOpenUrl(vm.value, device.value) : null)
const mounts = computed(() => visibleAppMounts({ compose: vm.value?.spec?.spec?.compose, sharedPaths: vm.value?.sharedPaths }))
const folderOpen = ref(false)
const pickedHost = ref('')
const portsOpen = ref(false)
const portDraft = ref<ComposePortRow[]>([])
const portsValid = computed(() => portDraft.value.every(isComposePortRow))
const envEditing = ref(false)
const envDraft = ref<{ key: string; value: string }[]>([])
const confirm = ref<'stop' | 'delete' | null>(null)
const keepVolumes = ref(true)
let epoch = 0
let timer: ReturnType<typeof setTimeout> | undefined

async function refresh(expectedEpoch = epoch) {
  await devices.fetchHealth()
  if (expectedEpoch !== epoch) return
  const path = base.value
  if (!path || !reachable.value) throw new Error('The app device is unavailable.')
  const { data } = await api.get<VM>(path)
  if (expectedEpoch !== epoch) return
  if (!isApplicationWorkload(data)) throw new Error('This workload is not a Docker app.')
  vm.value = data
  error.value = ''
  if (data.state === 'running') {
    try {
      const response = await api.get<MetricSample[]>(`${path}/metrics`, { params: { minutes: 30 } })
      if (expectedEpoch === epoch) metrics.value = response.data
    } catch {
      if (expectedEpoch === epoch) metrics.value = []
    }
  } else metrics.value = []
}

async function refreshLoop(expectedEpoch: number) {
  try {
    await refresh(expectedEpoch)
  } catch (e) {
    if (expectedEpoch === epoch) error.value = apiErrorMessage(e)
  } finally {
    if (expectedEpoch === epoch) {
      loading.value = false
      timer = setTimeout(() => { void refreshLoop(expectedEpoch) }, 5000)
    }
  }
}

watch([vmId, hostId], () => {
  epoch++
  clearTimeout(timer)
  stopTaskPoll()
  vm.value = null
  metrics.value = []
  error.value = ''
  loading.value = true
  terminalOpened.value = false
  envEditing.value = false
  portsOpen.value = false
  confirm.value = null
  tab.value = tabs.includes(String(route.query.tab)) ? String(route.query.tab) : 'overview'
  if (tab.value === 'terminal') terminalOpened.value = true
  void refreshLoop(epoch)
}, { immediate: true })

watch(tab, value => {
  if (value === 'terminal') terminalOpened.value = true
  void router.replace({ query: { ...route.query, tab: value } })
})
onUnmounted(() => { epoch++; clearTimeout(timer); stopTaskPoll() })

async function action(name: 'start' | 'stop' | 'restart' | 'update' | 'check-update' | 'delete') {
  if (!editable.value || !base.value || !device.value) return
  const path = base.value
  const target = device.value
  const actionEpoch = epoch
  busy.value = true
  try {
    if (name === 'delete' && vm.value?.state === 'running') await api.post(`${path}/stop`)
    const response = name === 'delete'
      ? await api.delete(path, { params: { keepDisk: keepVolumes.value } })
      : await api.post(`${path}/${name}`)
    if (response.data?.taskID) await poll(response.data.taskID, { path: deviceTaskPath(target, response.data.taskID) })
    if (actionEpoch !== epoch) return
    confirm.value = null
    if (name === 'delete') await router.push('/apps')
    else await refresh(actionEpoch)
  } catch (e) {
    toast.error(apiErrorMessage(e))
  } finally {
    busy.value = false
  }
}

async function toggleStartOnBoot(enabled: boolean) {
  if (!editable.value || !base.value) return
  const path = base.value
  const actionEpoch = epoch
  busy.value = true
  try {
    await api.patch(path, { startOnBoot: enabled })
    await refresh(actionEpoch)
  } catch (e) {
    toast.error(apiErrorMessage(e))
  } finally {
    busy.value = false
  }
}

async function saveSpec(change: (spec: WorkloadSpec) => void): Promise<boolean> {
  if (!editable.value || saving.value || !base.value) return false
  saving.value = true
  const path = base.value
  const saveEpoch = epoch
  try {
    const { data } = await api.get<WorkloadSpec>(`${path}/spec`)
    change(data)
    await api.put(`${path}/spec`, data)
    await refresh(saveEpoch)
    toast.success('App configuration saved. Restart the app to apply changes.')
    return true
  } catch (e) {
    toast.error(apiErrorMessage(e))
    return false
  } finally {
    saving.value = false
  }
}

function saveIngress(next: { enabled: boolean; mode: 'prefix' | 'direct' }) {
  return saveSpec(spec => { spec.spec.ingress = { ...spec.spec.ingress, ...next } })
}

function addMount(mount: ComposeMountDraft) {
  return saveSpec(spec => {
    const next = applyAppVolumeChange(spec.spec.compose ?? null, spec.spec.sharedPaths, { type: 'add', mount })
    if (next.compose !== null) spec.spec.compose = next.compose
    spec.spec.sharedPaths = next.sharedPaths
  })
}

function removeMount(mount: ComposeMount) {
  return saveSpec(spec => {
    const next = applyAppVolumeChange(spec.spec.compose ?? null, spec.spec.sharedPaths, { type: 'remove', mount })
    if (next.compose !== null) spec.spec.compose = next.compose
    spec.spec.sharedPaths = next.sharedPaths
  })
}

function editPorts() {
  portDraft.value = appPortEditorRows(parseComposePortSlots(vm.value?.spec?.spec?.compose ?? ''), vm.value?.publishedPorts ?? [])
  portsOpen.value = true
}

async function savePorts() {
  if (!portsValid.value) return
  if (await saveSpec(spec => { spec.spec.compose = setComposePorts(spec.spec.compose ?? '', portDraft.value) })) portsOpen.value = false
}

function editEnvironment() {
  envDraft.value = Object.entries(vm.value?.spec?.spec?.env ?? {})
    .filter(([key]) => !isSecretEnvKey(key)).map(([key, value]) => ({ key, value: value ?? '' }))
  envEditing.value = true
}

async function saveEnvironment() {
  const keys = envDraft.value.map(row => row.key.trim())
  if (keys.some(key => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(key) || isSecretEnvKey(key)) || new Set(keys).size !== keys.length) {
    toast.error('Use unique environment variable names. Secret variables are managed by the app template.')
    return
  }
  if (await saveSpec(spec => {
    const previous = Object.fromEntries(Object.entries(spec.spec.env ?? {}).filter(([key]) => !isSecretEnvKey(key)))
    const next = Object.fromEntries(envDraft.value.map(row => [row.key.trim(), row.value]))
    spec.spec.env = buildEnvSavePayload(spec.spec.env ?? {}, next)
    spec.spec.compose = setComposeEnvironment(spec.spec.compose ?? '', previous, next, Object.keys(spec.spec.env).length > 0)
  })) envEditing.value = false
}
</script>

<template>
  <div class="ops-page app-detail">
    <nav class="breadcrumb" aria-label="Breadcrumb"><router-link to="/apps">Apps</router-link><span v-if="vm"> / {{ vm.name }}</span></nav>
    <div class="ops-toolbar">
      <div><h1>{{ vm?.name || 'App' }}</h1><p class="ops-sub">{{ device ? devices.deviceLabel(device) : 'Loading device' }} · Docker Compose</p></div>
      <div v-if="vm" class="ops-actions">
        <a v-if="openUrl && vm.state === 'running'" :href="openUrl" target="_blank" rel="noopener">Open app</a>
        <AppButton v-if="vm.state === 'stopped' || vm.state === 'error'" :disabled="!editable" :loading="busy" @click="action('start')">Start</AppButton>
        <template v-else-if="vm.state === 'running'">
          <AppButton :disabled="!editable" @click="confirm = 'stop'">Stop</AppButton>
          <AppButton :disabled="!editable" :loading="busy" @click="action('restart')">Restart</AppButton>
        </template>
        <AppButton :disabled="!editable" :loading="busy" @click="action(vm.updateAvailable ? 'update' : 'check-update')">{{ vm.updateAvailable ? 'Update image' : 'Check for updates' }}</AppButton>
        <AppButton variant="danger" :disabled="!editable || !['running', 'stopped', 'error'].includes(vm.state)" @click="confirm = 'delete'">Delete</AppButton>
      </div>
    </div>
    <div class="ops-body">
      <p v-if="error" class="app-error" role="alert">{{ error }}</p>
      <p v-if="loading">Loading app…</p>
      <template v-if="vm">
        <div class="app-status">
          <span>{{ vm.state }}</span>
          <label><input type="checkbox" :checked="parseStartOnBoot(vm)" :disabled="!editable" @change="toggleStartOnBoot(($event.target as HTMLInputElement).checked)"> {{ startOnBootLabel() }}</label>
          <span v-if="vm.pendingChanges">Configuration changed. Restart to apply.</span>
        </div>
        <p v-if="vm.status?.healthError" class="app-error" role="alert">{{ vm.status.healthError }}</p>
        <nav class="app-tabs" aria-label="App sections">
          <button v-for="item in tabs" :key="item" type="button" :aria-current="tab === item ? 'page' : undefined" @click="tab = item">{{ item[0]?.toUpperCase() }}{{ item.slice(1) }}</button>
        </nav>
        <AppDetailOverview v-if="tab === 'overview'" :vm="vm" :device-label="device ? devices.deviceLabel(device) : ''" :open-url="openUrl"
          :metrics="metrics" :editable="editable && !saving" :saving-ingress="saving || !editable" :saving-volumes="saving" :saving-ports="saving" :picked-host="pickedHost"
          @update-ingress="saveIngress" @add-mount="addMount" @remove-mount="removeMount" @pick-host="folderOpen = true" @edit-ports="editPorts" />
        <AppTerminalSessions v-if="terminalOpened && auth.isAdmin" v-show="tab === 'terminal'" :key="`${hostId}:${vmId}`" :vm-id="vmId" :vm-state="vm.state" :device="device" :active="tab === 'terminal'" />
        <ComposeLogsPanel v-if="tab === 'logs'" :key="`${hostId}:${vmId}`" :vm-id="vmId" :device="device" />
        <section v-if="tab === 'volumes'" class="app-section">
          <h2>Persistent storage</h2>
          <AppMountList :mounts="mounts" :roots="vm.volumeRoots ?? []" :editable="editable" :busy="saving" :picked-host="pickedHost"
            @add-mount="addMount" @remove-mount="removeMount" @pick-host="folderOpen = true" />
        </section>
        <section v-if="tab === 'environment'" class="app-section">
          <h2>Environment</h2>
          <template v-if="!envEditing">
            <div v-for="(value, key) in vm.spec?.spec?.env" :key="key" class="env-row"><code>{{ key }}</code><code>{{ isSecretEnvKey(key) ? '••••••••' : value }}</code></div>
            <AppButton :disabled="!editable" @click="editEnvironment">Edit environment</AppButton>
          </template>
          <template v-else>
            <div v-for="(row, index) in envDraft" :key="index" class="env-row">
              <input v-model="row.key" aria-label="Variable name"><input v-model="row.value" :aria-label="`${row.key || 'Variable'} value`">
              <AppButton :disabled="saving" @click="envDraft.splice(index, 1)">Remove</AppButton>
            </div>
            <div class="editor-actions">
              <AppButton :disabled="saving" @click="envDraft.push({ key: '', value: '' })">Add variable</AppButton>
              <AppButton :disabled="saving" @click="envEditing = false">Cancel</AppButton>
              <AppButton :loading="saving" @click="saveEnvironment">Save</AppButton>
            </div>
          </template>
        </section>
      </template>
    </div>
    <AppModal v-if="portsOpen" title="Published ports" @close="portsOpen = false">
      <div v-for="(port, index) in portDraft" :key="index" class="env-row">
        <input v-model.number="port.hostPort" type="number" aria-label="Host port">
        <span>→</span><input v-model.number="port.containerPort" type="number" aria-label="Container port">
        <select v-model="port.proto" aria-label="Protocol"><option>tcp</option><option>udp</option></select>
        <AppButton @click="portDraft.splice(index, 1)">Remove</AppButton>
      </div>
      <div class="editor-actions">
        <AppButton @click="portDraft.push({ hostPort: 8080, containerPort: 80, proto: 'tcp' })">Add port</AppButton>
        <AppButton :disabled="!portsValid" :loading="saving" @click="savePorts">Save ports</AppButton>
      </div>
    </AppModal>
    <AppModal v-if="folderOpen" title="Choose a folder" @close="folderOpen = false">
      <FolderPicker :model-value="pickedHost" :device="device" @update:model-value="pickedHost = $event; folderOpen = false" @close="folderOpen = false" />
    </AppModal>
    <ConfirmDialog v-if="confirm === 'stop'" title="Stop app" :message="`Stop ${vm?.name}? Its containers will stop and persistent data will be kept.`" confirm-label="Stop" :loading="busy" @confirm="action('stop')" @cancel="confirm = null" />
    <AppModal v-if="confirm === 'delete'" title="Delete app" @close="confirm = null">
      <p>{{ vm?.state === 'running' ? 'Stop and delete' : 'Delete' }} {{ vm?.name }} and its containers?</p>
      <label><input v-model="keepVolumes" type="checkbox"> Keep persistent data</label>
      <div class="editor-actions"><AppButton variant="danger" :loading="busy" @click="action('delete')">Delete app</AppButton></div>
    </AppModal>
  </div>
</template>

<style scoped>
.breadcrumb { padding: 16px 20px 0; font-size: 13px; }
.app-status, .app-tabs, .editor-actions { display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 16px; }
.app-status { color: var(--text-secondary); }
.app-tabs { border-bottom: 1px solid var(--border); padding-bottom: 12px; }
.app-tabs button { border: 0; background: transparent; color: var(--text-secondary); cursor: pointer; padding: 8px 12px; }
.app-tabs button[aria-current] { color: var(--accent); box-shadow: 0 2px var(--accent); }
.app-section { padding: 20px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg-surface); }
.app-section h2 { margin-bottom: 16px; }
.env-row { display: flex; gap: 12px; align-items: center; margin-bottom: 12px; flex-wrap: wrap; }
.env-row input { min-width: 0; flex: 1; }
.env-row code { overflow-wrap: anywhere; }
.app-error { color: var(--red); margin-bottom: 16px; white-space: pre-wrap; }
.editor-actions { margin-top: 16px; }
</style>
