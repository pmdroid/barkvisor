<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import { useTemplateStore } from '../stores/templates'
import { useVMStore } from '../stores/vms'
import { useSSHKeyStore } from '../stores/sshKeys'
import { useDevicesStore } from '../stores/devices'
import { useHomeLibraryStore } from '../stores/homeLibrary'
import { defaultCapabilities, parseSystemCapabilities } from '../utils/capabilitiesParse'
import api from '../api/client'
import AppSelect from './ui/AppSelect.vue'
import UnsupportedHint from './ui/UnsupportedHint.vue'
import DevicePicker from './DevicePicker.vue'
import type {
  VMTemplate,
  DeployTemplateRequest,
  BridgeInfo,
  DeployTemplateResponse,
  TemplateCompatibilityReport,
  CurrentHostCapabilities,
  HomePlacementScoreResponse,
} from '../api/types'
import { useTaskPoller } from '../composables/useTaskPoller'
import { useImageProgress } from '../composables/useTicketedEventSource'
import {
  templateIncompatibilityReasons,
  toPickOption,
  type DevicePickOption,
} from '../utils/deviceCompatibility'
import {
  canCallDeviceAPI,
  defaultPickedHostId,
  deviceCapabilitiesPath,
  deviceImagePath,
  devicePath,
  deviceTaskPath,
  deviceVmActionPath,
  isSelfDevice,
} from '../utils/homeDeviceApi'
import {
  applyRecommendedHostId,
  isPlacementScoreAborted,
  isRecommendedHost,
  placementReasonsForHost,
  PLACEMENT_SCORE_DEBOUNCE_MS,
  scorePlacement,
} from '../utils/placement'
import { authorizedKeyForCloudInit } from '../utils/homeSSHKey'
import { natWebUILinks, templateDeclaresSshKeys } from '../utils/templateDeploy'

const props = defineProps<{ template: VMTemplate; initialHostId?: string }>()
const emit = defineEmits(['close', 'deployed'])

function networkModeLabel(mode: string): string {
  if (mode === 'bridged') return 'Bridged (Home Network)'
  if (mode === 'isolated') return 'Isolated (Private)'
  return 'NAT'
}

const templateStore = useTemplateStore()
const vmStore = useVMStore()
const sshKeyStore = useSSHKeyStore()
const devicesStore = useDevicesStore()
const homeLibrary = useHomeLibraryStore()

const selectedHostId = ref(props.initialHostId ?? '')
const userOverrodeHost = ref(!!props.initialHostId)
const placementScore = ref<HomePlacementScoreResponse | null>(null)
/** True while refreshPlacement assigns selectedHostId — not a user pick. */
let applyingRecommendedHost = false
let placementAbort: AbortController | null = null
let placementDebounce: ReturnType<typeof setTimeout> | undefined
const pickedCaps = ref<CurrentHostCapabilities | null>(null)
const selectedSSHKeyId = ref('')

const selectedDevice = computed(() => {
  if (selectedHostId.value) return devicesStore.deviceByHostId(selectedHostId.value)
  return devicesStore.selfDevice
})

const resolvedTemplate = computed(() =>
  homeLibrary.resolveTemplateForDeploy(props.template.slug, selectedDevice.value, props.template),
)

function hostHasDeployableTemplate(hostId: string): boolean {
  const device = devicesStore.deviceByHostId(hostId)
  if (!device) return false
  return homeLibrary.deviceHasDeployableTemplate(props.template.slug, device)
}

const deviceOptions = computed<DevicePickOption[]>(() => {
  const rows = devicesStore.devices
  const list = rows.length > 0 ? rows : (devicesStore.selfDevice ? [devicesStore.selfDevice] : [])
  return list.map((row) => {
    const local = templateIncompatibilityReasons(row, props.template, {
      capabilities: row.hostId === selectedDevice.value?.hostId
        ? (pickedCaps.value ?? defaultCapabilities)
        : undefined,
      hasTemplate: homeLibrary.deviceHasDeployableTemplate(props.template.slug, row),
    })
    const scored = placementScore.value?.candidates.find((candidate) => candidate.hostId === row.hostId)
    const hard = (scored?.reasons ?? [])
      .filter((reason) => reason.kind === 'hard')
      .map((reason) => reason.message)
    return toPickOption(row, [...new Set([...local, ...hard])], {
      recommended: isRecommendedHost(placementScore.value, row.hostId, hostHasDeployableTemplate),
      recommendReasons: placementReasonsForHost(placementScore.value, row.hostId),
    })
  })
})

const bridged = computed(() => ({
  available: pickedCaps.value?.supportsBridgedNetworking === true,
  explanation:
    pickedCaps.value?.details?.find((d) => d.code === 'bridgedNetworking' && !d.supported)?.remediation
    || undefined,
}))

// Bridge status for bridged templates
const bridgeAvailable = ref<boolean | null>(null) // null = loading
const bridgeChecked = ref(false)
const platformBridgeUnsupported = computed(
  () => props.template.networkMode === 'bridged' && !bridged.value.available,
)

const compatibility = ref<TemplateCompatibilityReport | null>(null)
let pickedDeviceLoadSeq = 0
let placementScoreSeq = 0

function isCurrentPickedDeviceLoad(seq: number): boolean {
  return seq === pickedDeviceLoadSeq
}

const vmName = ref('')
const cpuCount = ref(props.template.cpuCount)
const memoryMB = ref(props.template.memoryMB)
const diskSizeGB = ref(props.template.diskSizeGB)
const memoryFloor = computed(() => props.template.minMemoryMB ?? 128)
const memoryBelowMinimum = computed(() => {
  const planned = Number(memoryMB.value)
  return Number.isFinite(planned) && planned < memoryFloor.value
})

function plannedMemoryMB(): number {
  const planned = Number(memoryMB.value)
  return Number.isFinite(planned) ? planned : props.template.memoryMB
}

function assignRecommendedHostId(hostId: string) {
  if (hostId === selectedHostId.value) return
  applyingRecommendedHost = true
  selectedHostId.value = hostId
}

function cancelPlacementScore() {
  if (placementDebounce !== undefined) {
    clearTimeout(placementDebounce)
    placementDebounce = undefined
  }
  placementAbort?.abort()
  placementAbort = null
}

function schedulePlacementRefresh(applyRecommendation: boolean) {
  if (placementDebounce !== undefined) clearTimeout(placementDebounce)
  placementDebounce = setTimeout(() => {
    placementDebounce = undefined
    void refreshPlacement(applyRecommendation)
  }, PLACEMENT_SCORE_DEBOUNCE_MS)
}

async function refreshPlacement(applyRecommendation = true) {
  placementAbort?.abort()
  const ac = new AbortController()
  placementAbort = ac
  const seq = ++placementScoreSeq
  try {
    const data = await scorePlacement({
      declaredArchitectures: props.template.architectures ?? [],
      requiredFeatures: props.template.requiredFeatures ?? [],
      minMemoryMB: props.template.minMemoryMB,
      requestedMemoryMB: plannedMemoryMB(),
    }, { signal: ac.signal })
    if (seq !== placementScoreSeq) return
    placementScore.value = data
  } catch (error) {
    if (seq !== placementScoreSeq || isPlacementScoreAborted(error)) return
    placementScore.value = null
  }
  if (seq !== placementScoreSeq) return
  if (!applyRecommendation || userOverrodeHost.value) return
  assignRecommendedHostId(applyRecommendedHostId({
    recommendedHostId: placementScore.value?.recommendedHostId,
    initialHostId: props.initialHostId,
    selfHostId: devicesStore.selfDevice?.hostId,
    currentHostId: selectedHostId.value,
    hostAllowed: hostHasDeployableTemplate,
  }))
}

async function loadPickedDevice() {
  const seq = ++pickedDeviceLoadSeq
  await devicesStore.fetchHealth().catch(() => {})
  if (!isCurrentPickedDeviceLoad(seq)) return
  if (homeLibrary.templates.length === 0) {
    await homeLibrary.fetchAll(devicesStore.devices).catch(() => {})
    if (!isCurrentPickedDeviceLoad(seq)) return
  }
  await refreshPlacement()
  if (!isCurrentPickedDeviceLoad(seq)) return
  if (!selectedHostId.value) {
    assignRecommendedHostId(defaultPickedHostId(props.initialHostId, devicesStore.selfDevice?.hostId))
  }
  const device = selectedDevice.value
  await sshKeyStore.fetchAll().catch(() => {})
  if (!isCurrentPickedDeviceLoad(seq)) return
  if (!selectedSSHKeyId.value || !sshKeyStore.keys.some((k) => k.id === selectedSSHKeyId.value)) {
    selectedSSHKeyId.value = sshKeyStore.defaultKey?.id ?? ''
  }
  if (!device) {
    pickedCaps.value = null
    return
  }
  if (!canCallDeviceAPI(device)) {
    pickedCaps.value = null
    bridgeAvailable.value = false
    bridgeChecked.value = true
    return
  }
  try {
    const { data } = await api.get(deviceCapabilitiesPath(device))
    if (!isCurrentPickedDeviceLoad(seq)) return
    pickedCaps.value = parseSystemCapabilities(data)
  } catch {
    if (!isCurrentPickedDeviceLoad(seq)) return
    pickedCaps.value = null
  }
  if (props.template.networkMode === 'bridged' && bridged.value.available && device) {
    try {
      const { data } = await api.get<BridgeInfo[]>(devicePath(device, '/system/bridges'))
      if (!isCurrentPickedDeviceLoad(seq)) return
      bridgeAvailable.value = data.some((b) => b.status === 'active')
    } catch {
      if (!isCurrentPickedDeviceLoad(seq)) return
      bridgeAvailable.value = false
    }
    bridgeChecked.value = true
  } else if (props.template.networkMode === 'bridged') {
    bridgeAvailable.value = false
    bridgeChecked.value = true
  } else {
    bridgeAvailable.value = true
    bridgeChecked.value = true
  }
  if (!isCurrentPickedDeviceLoad(seq)) return
  await refreshCompatibility(selectedHostId.value)
}

onMounted(async () => {
  await loadPickedDevice()
})

watch(selectedHostId, async (next, prev) => {
  const programmatic = applyingRecommendedHost
  applyingRecommendedHost = false
  if (!next || next === prev) return
  if (!programmatic) userOverrodeHost.value = true
  if (programmatic) return
  await loadPickedDevice()
  await refreshCompatibility()
})

const step = ref(1)
const totalSteps = computed(() => visibleInputs.value.length > 0 ? 3 : 2)

async function refreshCompatibility(expectedHostId = selectedHostId.value) {
  try {
    const planned = Number(memoryMB.value)
    const device = selectedDevice.value
    const templateId = resolvedTemplate.value?.id
    if (!templateId) {
      if (selectedHostId.value !== expectedHostId) return
      compatibility.value = null
      return
    }
    const report = await templateStore.dryRun(
      templateId,
      { memoryMB: Number.isFinite(planned) ? planned : undefined },
      device ?? undefined,
    )
    if (selectedHostId.value !== expectedHostId) return
    compatibility.value = report
  } catch {
    if (selectedHostId.value !== expectedHostId) return
    compatibility.value = null
  }
}

watch(memoryMB, (_next, prev) => {
  void refreshCompatibility()
  if (prev !== undefined) schedulePlacementRefresh(false)
}, { immediate: true })

const showsSshPicker = computed(() => templateDeclaresSshKeys(props.template.inputs))
const webUILinks = computed(() =>
  natWebUILinks({
    templateName: props.template.name,
    networkMode: props.template.networkMode,
    isSelfDevice: selectedDevice.value ? isSelfDevice(selectedDevice.value) : true,
    portForwards: props.template.portForwards,
  }),
)

// Step 2: Template inputs (dynamic) — ssh_keys is handled by the dedicated SSH key selector
const visibleInputs = computed(() => props.template.inputs.filter(i => i.id !== 'ssh_keys'))
const inputValues = ref<Record<string, string>>({})
for (const input of props.template.inputs) {
  if (input.id === 'ssh_keys') continue
  inputValues.value[input.id] = input.default ?? ''
}

// State
const error = ref('')
const loading = ref(false)

// Download progress state
const phase = ref<'form' | 'downloading' | 'deploying' | 'done'>('form')
const downloadPercent = ref(0)
const downloadStatus = ref('')
const imageProgress = useImageProgress()
let drawerClosed = false

onUnmounted(() => {
  drawerClosed = true
  imageProgress.stop()
  cancelPlacementScore()
})

function canProceed(): boolean {
  if (step.value === 1) return !!vmName.value.trim()
  if (step.value === 2 && visibleInputs.value.length > 0) {
    return visibleInputs.value
      .filter(i => i.required)
      .every(i => {
        const val = inputValues.value[i.id] ?? ''
        if (!val) return false
        if (i.minLength && val.length < i.minLength) return false
        return true
      })
  }
  return true
}

function next() {
  if (canProceed() && step.value < totalSteps.value) step.value++
}

function prev() {
  if (step.value > 1) step.value--
}

function buildRequest(): DeployTemplateRequest {
  const resolved = resolvedTemplate.value
  if (!resolved) {
    throw new Error("Not in this Device's Library")
  }
  const inputs = { ...inputValues.value }
  if (showsSshPicker.value) {
    const selectedKey = sshKeyStore.keys.find(k => k.id === selectedSSHKeyId.value)
    if (selectedKey) {
      inputs.ssh_keys = authorizedKeyForCloudInit(selectedKey)
    }
  }
  return {
    templateId: resolved.id,
    vmName: vmName.value.trim(),
    inputs,
    cpuCount: cpuCount.value !== props.template.cpuCount ? cpuCount.value : undefined,
    memoryMB: memoryMB.value !== props.template.memoryMB ? memoryMB.value : undefined,
    diskSizeGB: diskSizeGB.value !== props.template.diskSizeGB ? diskSizeGB.value : undefined,
  }
}

async function pollRemoteImage(imageId: string) {
  const device = selectedDevice.value
  if (!device || drawerClosed) return
  phase.value = 'downloading'
  downloadPercent.value = 0
  downloadStatus.value = 'Downloading image on the picked Device...'
  try {
    for (let i = 0; i < 600; i++) {
      if (drawerClosed) return
      const { data } = await api.get(deviceImagePath(device, imageId))
      if (drawerClosed) return
      if (data.status === 'ready') {
        await doDeploy()
        return
      }
      if (data.status === 'error') {
        error.value = data.error || 'Image download failed'
        phase.value = 'form'
        return
      }
      await new Promise((resolve) => setTimeout(resolve, 1000))
    }
    if (drawerClosed) return
    error.value = 'Timed out waiting for the Device image download'
    phase.value = 'form'
  } catch (e: unknown) {
    if (drawerClosed) return
    error.value = apiErrorMessage(e, 'Image download failed')
    phase.value = 'form'
  }
}

function watchDownload(imageId: string) {
  const device = selectedDevice.value
  if (device && !isSelfDevice(device)) {
    void pollRemoteImage(imageId)
    return
  }
  phase.value = 'downloading'
  downloadPercent.value = 0
  downloadStatus.value = 'Starting download...'

  let settled = false
  const finishReady = () => {
    if (settled || drawerClosed) return
    settled = true
    imageProgress.stop()
    void doDeploy()
  }
  const finishError = (message: string) => {
    if (settled || drawerClosed) return
    settled = true
    imageProgress.stop()
    error.value = message
    phase.value = 'form'
  }

  const pollLibraryRow = async () => {
    try {
      for (let i = 0; i < 600; i++) {
        if (drawerClosed || settled) return
        if (imageProgress.isActive()) {
          await new Promise((resolve) => setTimeout(resolve, 1000))
          continue
        }
        const { data } = await api.get(`/images/${imageId}`)
        if (drawerClosed || settled) return
        if (data.status === 'ready') {
          finishReady()
          return
        }
        if (data.status === 'error') {
          finishError(data.error || 'Image download failed')
          return
        }
        await new Promise((resolve) => setTimeout(resolve, 1000))
      }
      finishError('Timed out waiting for the Device image download')
    } catch (e: unknown) {
      if (!settled && !drawerClosed) finishError(apiErrorMessage(e, 'Image download failed'))
    }
  }

  imageProgress.start(imageId, {
    onProgress: (data) => {
      if (data.status === 'downloading') {
        downloadPercent.value = data.percent ?? 0
        const mb = Math.round((data.bytesReceived || 0) / 1024 / 1024)
        const totalMb = data.totalBytes ? Math.round(data.totalBytes / 1024 / 1024) : null
        downloadStatus.value = totalMb
          ? `Downloading image... ${mb} / ${totalMb} MB`
          : `Downloading image... ${mb} MB`
      } else if (data.status === 'decompressing') {
        downloadStatus.value = 'Decompressing image...'
        downloadPercent.value = 100
      }
    },
    onReady: () => {
      finishReady()
    },
    onError: (data) => {
      if (data) {
        finishError(data.error || 'Image download failed')
        return
      }
      // SSE disconnected; poll the Library row as the single fallback.
      void pollLibraryRow()
    },
  })
}

async function finishDeploy(result: DeployTemplateResponse) {
  if (drawerClosed) return
  if (result.status === 'downloading' && result.imageId) {
    watchDownload(result.imageId)
    return
  }

  const device = selectedDevice.value
  const localList = !device || isSelfDevice(device)

  if (result.status === 'provisioning' && result.vm && result.taskID) {
    if (localList && !vmStore.vms.find(v => v.id === result.vm!.id)) {
      vmStore.vms.push(result.vm)
    }
    phase.value = 'deploying'
    downloadStatus.value = 'Provisioning disk from cloud image...'
    const { poll } = useTaskPoller()
    const event = await poll(result.taskID, {
      path: device ? deviceTaskPath(device, result.taskID) : undefined,
    })
    if (drawerClosed) return
    if (event.status !== 'completed') {
      error.value = event.error || 'Provisioning failed'
      phase.value = 'form'
      return
    }
    try {
      if (device && !isSelfDevice(device)) {
        await api.post(deviceVmActionPath(device, result.vm.id, 'start'))
      } else {
        await vmStore.start(result.vm.id)
      }
    } catch {
      // VM is created; start can fail if host lacks accel — still report deployed.
    }
    if (drawerClosed) return
    phase.value = 'done'
    emit('deployed', result.vm, device?.hostId)
    return
  }

  if (result.status === 'created' && result.vm) {
    if (localList && !vmStore.vms.find(v => v.id === result.vm!.id)) {
      vmStore.vms.push(result.vm)
    }
    try {
      if (device && !isSelfDevice(device)) {
        await api.post(deviceVmActionPath(device, result.vm.id, 'start'))
      } else {
        await vmStore.start(result.vm.id)
      }
    } catch {
      /* ignore */
    }
    if (drawerClosed) return
    phase.value = 'done'
    emit('deployed', result.vm, device?.hostId)
  }
}

async function doDeploy() {
  if (drawerClosed) return
  if (!resolvedTemplate.value) {
    error.value = "Not in this Device's Library"
    phase.value = 'form'
    return
  }
  phase.value = 'deploying'
  downloadStatus.value = 'Creating VM...'
  error.value = ''

  try {
    const result = await templateStore.deploy(buildRequest(), selectedDevice.value ?? undefined)
    if (drawerClosed) return
    await finishDeploy(result)
  } catch (e: any) {
    if (drawerClosed) return
    error.value = apiErrorMessage(e)
    phase.value = 'form'
  }
}

async function submit() {
  error.value = ''
  if (!resolvedTemplate.value) {
    error.value = "Not in this Device's Library"
    return
  }
  await refreshPlacement(false)
  if (platformBridgeUnsupported.value) {
    error.value = bridged.value.explanation || 'Bridged networking is not available on this device.'
    return
  }
  loading.value = true
  try {
    const result = await templateStore.deploy(buildRequest(), selectedDevice.value ?? undefined)
    if (drawerClosed) return
    await finishDeploy(result)
  } catch (e: any) {
    if (drawerClosed) return
    error.value = apiErrorMessage(e)
  } finally {
    if (!drawerClosed) loading.value = false
  }
}
</script>

<template>
  <div class="modal-overlay" @click.self="emit('close')">
    <div class="modal" style="max-width:520px">
      <h2>Deploy {{ template.name }}</h2>
      <p style="color:var(--text-dim);font-size:13px;margin-bottom:16px">{{ template.description }}</p>
      <DevicePicker
        v-if="phase === 'form' && deviceOptions.length > 0"
        v-model="selectedHostId"
        :options="deviceOptions"
      />
      <p
        v-if="compatibility?.resolvedImageSlug"
        style="color:var(--text-dim);font-size:12px;margin:-8px 0 16px"
      >
        Image for this device: {{ compatibility.resolvedImageSlug }}
      </p>
      <div
        v-if="compatibility && !compatibility.compatible"
        class="bridge-error"
        style="margin-bottom:16px"
      >
        <div>
          <strong>Not recommended for this Device</strong>
          <p style="margin:4px 0 0;font-size:12px;color:var(--text-secondary)">
            You can still deploy here.
          </p>
          <p
            v-for="reason in compatibility.reasons"
            :key="reason.code + reason.message"
            style="margin:4px 0 0;font-size:12px;color:var(--text-secondary)"
          >
            {{ reason.message }}
          </p>
        </div>
      </div>

      <!-- Bridge not available warning -->
      <div v-if="template.networkMode === 'bridged' && bridgeChecked && !bridgeAvailable" class="bridge-error">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="flex-shrink:0">
          <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
        </svg>
        <div>
          <strong>Bridged networking required</strong>
          <UnsupportedHint
            v-if="platformBridgeUnsupported"
            :text="bridged.explanation"
          />
          <p v-else style="margin:4px 0 0;font-size:12px;color:var(--text-secondary)">
            This template requires a bridge network but no active bridge was found.
            Install the BarkVisor Helper and enable a bridge under <router-link to="/networks"><strong>Networks</strong></router-link>.
          </p>
        </div>
      </div>

      <!-- Downloading / Deploying phase -->
      <div v-if="phase === 'downloading' || phase === 'deploying'" style="padding:24px 0">
        <div style="text-align:center;margin-bottom:16px">
          <div style="font-size:14px;font-weight:500;margin-bottom:8px">
            {{ phase === 'downloading' ? 'Downloading Image' : 'Deploying VM' }}
          </div>
          <div style="font-size:13px;color:var(--text-dim)">{{ downloadStatus }}</div>
        </div>
        <div class="progress-bar-track">
          <div class="progress-bar-fill"
            :style="{ width: phase === 'deploying' ? '100%' : downloadPercent + '%' }"
            :class="{ indeterminate: phase === 'deploying' }" />
        </div>
        <div v-if="phase === 'downloading'" style="text-align:center;margin-top:8px;font-size:12px;color:var(--text-dim)">
          {{ downloadPercent }}%
        </div>
        <div v-if="error" class="error-box" style="margin-top:16px">{{ error }}</div>
      </div>

      <div v-else-if="phase === 'done'" style="padding:8px 0 0">
        <p style="font-size:14px;margin-bottom:12px">{{ template.name }} is deployed.</p>
        <p
          v-if="webUILinks.length === 0 && template.networkMode === 'nat' && selectedDevice && !isSelfDevice(selectedDevice)"
          style="font-size:13px;color:var(--text-dim);margin-bottom:12px"
        >
          Open the web UI on the Device that hosts this Workload. 127.0.0.1 in this browser is the wrong machine.
        </p>
        <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:16px">
          <a
            v-for="link in webUILinks"
            :key="link.href"
            class="btn-primary"
            :href="link.href"
            target="_blank"
            rel="noopener"
          >{{ link.label }}</a>
        </div>
        <div style="display:flex;justify-content:flex-end">
          <button class="btn-ghost" @click="emit('close')">Close</button>
        </div>
      </div>

      <!-- Form phase -->
      <template v-else-if="phase === 'form'">
        <!-- Step indicator -->
        <div class="wizard-steps">
          <template v-for="s in totalSteps" :key="s">
            <div v-if="s > 1" class="wizard-line" :class="{ done: s <= step }" />
            <button class="wizard-dot"
              :class="{ active: s === step, done: s < step }"
              :disabled="s > step"
              @click="s < step ? step = s : null">
              <svg v-if="s < step" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="20 6 9 17 4 12"/></svg>
              <span v-else>{{ s }}</span>
            </button>
          </template>
        </div>

        <!-- Step 1: Name & Resources -->
        <div v-if="step === 1">
          <h3 class="step-title">VM Name & Resources</h3>
          <div class="form-group">
            <label>VM Name</label>
            <input v-model="vmName" :placeholder="`my-${template.slug}`" @keyup.enter="next" autofocus />
          </div>
          <div style="display:flex;gap:12px">
            <div class="form-group" style="flex:1">
              <label>CPU Cores</label>
              <input v-model.number="cpuCount" type="number" min="1" max="16" />
            </div>
            <div class="form-group" style="flex:1">
              <label>Memory (MB)</label>
              <input v-model.number="memoryMB" type="number" :min="memoryFloor" step="256" />
            </div>
          </div>
          <div class="form-group">
            <label>Disk Size (GB)</label>
            <input v-model.number="diskSizeGB" type="number" min="1" />
          </div>
          <div v-if="showsSshPicker" class="form-group">
            <label>SSH Key</label>
            <AppSelect v-model="selectedSSHKeyId">
              <option value="">None</option>
              <option v-for="sk in sshKeyStore.keys" :key="sk.id" :value="sk.id">
                {{ sk.name }}
              </option>
            </AppSelect>
            <div v-if="sshKeyStore.keys.length === 0" style="margin-top:6px;font-size:12px;color:var(--text-dim)">
              No SSH keys on Home yet. Add keys in Settings first.
            </div>
          </div>
          <div style="display:flex;gap:8px;align-items:center;margin-top:4px;font-size:12px;color:var(--text-dim)">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
              <path v-if="template.networkMode === 'bridged'" d="M9 2H5a2 2 0 00-2 2v4m6-6h10a2 2 0 012 2v4M9 2v6m12-2H9m12 0v12a2 2 0 01-2 2H9m12-14H9m0 14H5a2 2 0 01-2-2V8m6 14V8m0 0H3" />
              <path v-else d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
            </svg>
            Network: <strong>{{ networkModeLabel(template.networkMode) }}</strong>
            <span v-if="template.networkMode === 'bridged'" style="color:var(--text-dim)">(gets its own IP on your LAN)</span>
            <span v-else-if="template.networkMode === 'isolated'" style="color:var(--text-dim)">(Private — no host/LAN/internet)</span>
          </div>
          <div v-if="template.portForwards && template.portForwards.length > 0 && template.networkMode === 'nat'" style="margin-top:12px">
            <label style="font-size:12px;color:var(--text-dim)">Port Forwards (auto-configured)</label>
            <div v-for="pf in template.portForwards" :key="`${pf.hostPort}-${pf.guestPort}`"
              style="font-size:12px;color:var(--text-dim);padding:2px 0">
              {{ pf.protocol.toUpperCase() }} host:{{ pf.hostPort }} &rarr; guest:{{ pf.guestPort }}
            </div>
          </div>
        </div>

        <!-- Step 2: Template inputs (dynamic) -->
        <div v-if="step === 2 && visibleInputs.length > 0">
          <h3 class="step-title">Configuration</h3>
          <div v-for="input in visibleInputs" :key="input.id" class="form-group">
            <label>
              {{ input.label }}
              <span v-if="input.required" style="color:var(--danger)">*</span>
            </label>
            <textarea
              v-if="input.type === 'textarea'"
              v-model="inputValues[input.id]"
              :placeholder="input.placeholder"
              rows="3"
            />
            <input
              v-else
              v-model="inputValues[input.id]"
              :type="input.type"
              :placeholder="input.placeholder"
            />
            <span v-if="input.minLength" style="font-size:11px;color:var(--text-dim);display:block;margin-top:2px">
              Minimum {{ input.minLength }} characters
            </span>
          </div>
        </div>

        <!-- Review step (last step) -->
        <div v-if="step === totalSteps">
          <h3 class="step-title">Review</h3>
          <div style="font-size:13px;line-height:1.8">
            <div><strong>Template:</strong> {{ template.name }}</div>
            <div v-if="selectedDevice"><strong>Device:</strong> {{ selectedDevice.displayName || selectedDevice.hostId }}</div>
            <div><strong>VM Name:</strong> {{ vmName }}</div>
            <div><strong>CPU:</strong> {{ cpuCount }} cores</div>
            <div><strong>Memory:</strong> {{ memoryMB }} MB</div>
            <div><strong>Disk:</strong> {{ diskSizeGB }} GB</div>
            <div><strong>Network:</strong> {{ networkModeLabel(template.networkMode) }}</div>
            <div v-if="showsSshPicker"><strong>SSH Key:</strong> {{ sshKeyStore.keys.find(k => k.id === selectedSSHKeyId)?.name || 'None' }}</div>
            <div><strong>Image:</strong> {{ compatibility?.resolvedImageSlug || template.imageSlug }}</div>
          </div>
        </div>

        <div v-if="error" class="error-box">{{ error }}</div>

        <div style="display:flex;justify-content:space-between;margin-top:20px">
          <button v-if="step > 1" class="btn-ghost" @click="prev">Back</button>
          <span v-else />
          <button v-if="step < totalSteps" class="btn-primary" :disabled="!canProceed()" @click="next">
            Next
          </button>
          <button v-else class="btn-primary" :disabled="!canProceed() || loading || !resolvedTemplate || (template.networkMode === 'bridged' && !bridgeAvailable) || memoryBelowMinimum || (deviceOptions.length > 0 && !deviceOptions.some(o => o.hostId === selectedHostId && o.reachable))" @click="submit">
            {{ loading ? 'Deploying...' : 'Deploy' }}
          </button>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.wizard-steps {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0;
  margin-bottom: 20px;
}
.wizard-dot {
  width: 28px;
  height: 28px;
  border-radius: 2px;
  border: 2px solid var(--border);
  background: transparent;
  color: var(--text-dim);
  font-size: 12px;
  font-weight: 600;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: default;
  transition: all 0.2s;
  padding: 0;
  flex-shrink: 0;
}
.wizard-dot.active {
  border-color: var(--accent);
  background: var(--accent);
  color: #fff;
}
.wizard-dot.done {
  border-color: var(--accent);
  background: var(--accent);
  color: #fff;
  cursor: pointer;
}
.wizard-dot:disabled {
  opacity: 0.5;
  cursor: default;
}
.wizard-line {
  height: 2px;
  width: 40px;
  background: var(--border);
  flex-shrink: 0;
  transition: background 0.2s;
}
.wizard-line.done {
  background: var(--accent);
}
.step-title {
  font-size: 14px;
  font-weight: 600;
  margin-bottom: 14px;
}
.progress-bar-track {
  height: 4px;
  background: var(--bg-hover);
  border-radius: 2px;
  overflow: hidden;
}
.progress-bar-fill {
  height: 100%;
  background: var(--primary);
  border-radius: 2px;
  transition: width 0.3s ease;
}
.progress-bar-fill.indeterminate {
  width: 100% !important;
  animation: indeterminate 1.5s ease-in-out infinite;
  background: linear-gradient(90deg, var(--primary) 0%, var(--primary) 40%, transparent 40%, transparent 60%, var(--primary) 60%);
  background-size: 200% 100%;
}
@keyframes indeterminate {
  0% { background-position: 100% 0; }
  100% { background-position: -100% 0; }
}
.bridge-error {
  display: flex;
  gap: 10px;
  align-items: flex-start;
  padding: 12px 14px;
  background: rgba(239, 68, 68, 0.08);
  border: 1px solid rgba(239, 68, 68, 0.25);
  border-radius: var(--radius-sm);
  margin-bottom: 16px;
  font-size: 13px;
  color: var(--red, #ef4444);
}
</style>
