<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import type { AppTemplateField, HostGPUShareDevice, SystemCapabilities } from '../api/types'
import { useCreateProgressStore } from '../stores/createProgress'
import { useDevicesStore } from '../stores/devices'
import { useHomeLibraryStore, type HomeApp } from '../stores/homeLibrary'
import { useFeature } from '../composables/useFeature'
import { deviceGpuSharePath, devicePath, isSelfDevice } from '../utils/homeDeviceApi'
import { defaultGPUShareIds, gpuShareOccupancy, gpuShareVisible } from '../utils/gpuShare'
import { DEVICE_LABEL } from '../utils/terminology'
import {
  appArchLabel,
  appCatalogKey,
  appInstallBlockedReason,
  appSourceLabel,
  appSupportsDeviceArch,
} from '../utils/appCatalog'
import {
  APP_GALLERY_ALL_CATEGORY,
  appGalleryFilterSummary,
  filterAppGallery,
} from '../utils/appGalleryFilter'
import {
  applicationDocument,
  applyDevicePrefill,
  catalogFields,
  catalogProxy,
  envName,
  fieldError,
  generateSecret,
  isAdvancedField,
  managedEnvPreview,
  missingRequiredField,
  openUIURL,
  seedTemplateValues,
  uiPortField,
  type AppTemplateExtraFolder,
  type AppTemplateValues,
} from '../utils/appTemplate'
import {
  applyComposeDocumentDrafts,
  composeMountFromDraft,
  ensureApplicationSharedPaths,
  extractComposeBlock,
  isComposePortRow,
  parseComposeMountSlots,
  parseComposePortSlots,
  type ComposeMountDraft,
  type ComposePortRow,
} from '../utils/composeEdit'
import AppButton from './ui/AppButton.vue'
import AppSelect from './ui/AppSelect.vue'
import AppGalleryToolbar from './AppGalleryToolbar.vue'
import FolderPicker from './FolderPicker.vue'

const props = defineProps<{ initialHostId?: string }>()
const emit = defineEmits(['close', 'created'])

const devices = useDevicesStore()
const homeLibrary = useHomeLibraryStore()
const createProgress = useCreateProgressStore()
const docker = useFeature('dockerEngine')

const step = ref<'gallery' | 'configure'>('gallery')
const galleryQuery = ref('')
const galleryCategory = ref(APP_GALLERY_ALL_CATEGORY)
const visibleApps = computed(() =>
  filterAppGallery(homeLibrary.apps, { query: galleryQuery.value, category: galleryCategory.value }),
)
const galleryFilterSummary = computed(() =>
  appGalleryFilterSummary({ query: galleryQuery.value, category: galleryCategory.value }),
)
const selected = ref<HomeApp | null>(null)
const customYaml = ref(false)
const yaml = ref(`apiVersion: barkvisor.dev/v1
kind: Application
metadata:
  name: whoami
spec:
  runtime: device
  compose: |
    services:
      whoami:
        image: traefik/whoami
        ports:
          - "8080:80"
        restart: unless-stopped
`)
const name = ref('')
const hostId = ref(props.initialHostId || devices.selfDevice?.hostId || '')
const submitting = ref(false)
const error = ref('')
const values = ref<AppTemplateValues>({})
const extraFolders = ref<AppTemplateExtraFolder[]>([])
const extraEnv = ref<{ name: string; value: string }[]>([])
const openThrough = ref(true)
const modeOverride = ref('')
const portOverride = ref('')
const advancedOpen = ref(false)
const pickerFieldId = ref<string | null>(null)
const pickerExtraIndex = ref<number | null>(null)
const yamlVolumes = ref<ComposeMountDraft[]>([])
const yamlPorts = ref<ComposePortRow[]>([])
const yamlVolumeDirty = ref(false)
const yamlPortDirty = ref(false)
const pickerYamlIndex = ref<number | null>(null)
const lanIPv4 = ref('')
const showErrors = ref(false)
const gpuShare = ref<HostGPUShareDevice[]>([])
const selectedGPUIds = ref<string[]>([])

const selectedDevice = computed(() => devices.deviceByHostId(hostId.value) || devices.selfDevice)
const deviceArch = computed(() => selectedDevice.value?.platform?.arch ?? null)
const dockerOnDevice = computed(() => {
  if (!selectedDevice.value) return docker.available
  if (isSelfDevice(selectedDevice.value)) return docker.available
  return selectedDevice.value.features?.dockerEngine === true
})

const dockerBlocked = computed(() => {
  if (dockerOnDevice.value) return ''
  if (isSelfDevice(selectedDevice.value || { hostId: '', role: 'self' })) {
    return docker.explanation || 'The selected Device does not have dockerEngine.'
  }
  return 'The selected Device does not have dockerEngine.'
})

const archMismatch = computed(() => {
  if (!selected.value) return false
  return !appSupportsDeviceArch(selected.value, deviceArch.value)
})

const blockedReason = computed(() => {
  if (customYaml.value) return dockerBlocked.value
  if (!selected.value) return ''
  return appInstallBlockedReason(selected.value, deviceArch.value, dockerOnDevice.value)
})

const digestLine = computed(() => {
  if (!selected.value) return ''
  if (selected.value.digest) return selected.value.digest
  return selected.value.image || ''
})

const fields = computed(() => (selected.value ? catalogFields(selected.value) : []))
const folderFields = computed(() => fields.value.filter((field) => field.kind === 'path'))
const secretFields = computed(() => fields.value.filter((field) => field.kind === 'secret'))
const portFields = computed(() => fields.value.filter((field) => field.kind === 'port'))
const envFields = computed(() =>
  fields.value.filter((field) => field.kind !== 'path' && field.kind !== 'secret' && field.kind !== 'port' && !isAdvancedField(field)),
)
const advancedFields = computed(() => fields.value.filter((field) => isAdvancedField(field)))
const installTip = computed(() => selected.value?.ui?.tips?.before_install || '')
const applyBlockedField = computed(() => missingRequiredField(fields.value, values.value))
const uiField = computed(() => uiPortField(fields.value))
const resolvedMode = computed(() => {
  if (modeOverride.value === 'prefix' || modeOverride.value === 'direct') return modeOverride.value
  return selected.value ? catalogProxy(selected.value) : 'direct'
})
const managedKeys = computed(() =>
  selected.value ? managedEnvPreview(selected.value, openThrough.value, resolvedMode.value) : [],
)
const openUIPreview = computed(() => {
  if (!selected.value) return ''
  if (openThrough.value && resolvedMode.value === 'prefix') {
    const device = selectedDevice.value
    if (device && !isSelfDevice(device)) {
      return `/home/devices/${encodeURIComponent(device.hostId)}/go/<id>/`
    }
    return '/go/<id>/'
  }
  if (!uiField.value || !lanIPv4.value) return ''
  const port = Number(portOverride.value || values.value[uiField.value.id] || uiField.value.default || 0)
  if (!port) return ''
  return openUIURL({
    scheme: selected.value.ui.scheme,
    path: selected.value.ui.path,
    host: lanIPv4.value,
    port,
  })
})

watch(hostId, () => {
  void loadDevicePrefill()
})

onMounted(() => {
  void homeLibrary.fetchApps(devices.devices)
  void loadDevicePrefill()
})

async function loadDevicePrefill() {
  const device = selectedDevice.value
  if (!device) return
  try {
    const { data } = await api.get<SystemCapabilities>(devicePath(device, '/system/capabilities'))
    lanIPv4.value = data.lanIPv4 || ''
    if (fields.value.length) {
      values.value = applyDevicePrefill(fields.value, values.value, {
        puid: data.puid,
        pgid: data.pgid,
        timezone: data.timezone,
      })
    }
  } catch {
    lanIPv4.value = ''
  }
  try {
    const { data } = await api.get<HostGPUShareDevice[]>(deviceGpuSharePath(device))
    gpuShare.value = data || []
    selectedGPUIds.value = defaultGPUShareIds(gpuShare.value)
  } catch {
    gpuShare.value = []
    selectedGPUIds.value = []
  }
}

function toggleGPU(id: string, on: boolean) {
  if (on) {
    if (!selectedGPUIds.value.includes(id)) selectedGPUIds.value = [...selectedGPUIds.value, id]
    return
  }
  selectedGPUIds.value = selectedGPUIds.value.filter((row) => row !== id)
}

function pickApp(app: HomeApp) {
  selected.value = app
  customYaml.value = false
  name.value = app.id
  showErrors.value = false
  extraFolders.value = []
  extraEnv.value = []
  yamlVolumes.value = []
  yamlPorts.value = []
  pickerYamlIndex.value = null
  openThrough.value = true
  modeOverride.value = ''
  portOverride.value = ''
  values.value = seedTemplateValues(catalogFields(app))
  step.value = 'configure'
  void loadDevicePrefill()
}

function setField(id: string, value: string) {
  values.value = { ...values.value, [id]: value }
}

function fieldKind(field: AppTemplateField): string {
  return field.kind
}

function isClaim(field: AppTemplateField): boolean {
  return envName(field) === 'PLEX_CLAIM'
}

function addFolder() {
  extraFolders.value = [...extraFolders.value, { hostPath: '', containerPath: '/data' }]
}

function removeFolder(index: number) {
  extraFolders.value = extraFolders.value.filter((_, i) => i !== index)
}

function setExtraHost(index: number, path: string) {
  extraFolders.value = extraFolders.value.map((row, i) => (i === index ? { ...row, hostPath: path } : row))
}

function setExtraContainer(index: number, path: string) {
  extraFolders.value = extraFolders.value.map((row, i) => (i === index ? { ...row, containerPath: path } : row))
}

function onExtraPicked(path: string) {
  if (pickerExtraIndex.value === null) return
  setExtraHost(pickerExtraIndex.value, path)
  pickerExtraIndex.value = null
}

function addEnv() {
  extraEnv.value = [...extraEnv.value, { name: '', value: '' }]
}

function setExtraEnvName(index: number, name: string) {
  extraEnv.value = extraEnv.value.map((row, i) => (i === index ? { ...row, name } : row))
}

function setExtraEnvValue(index: number, value: string) {
  extraEnv.value = extraEnv.value.map((row, i) => (i === index ? { ...row, value } : row))
}

function removeEnv(index: number) {
  extraEnv.value = extraEnv.value.filter((_, i) => i !== index)
}

function extraEnvRecord(): Record<string, string> {
  const out: Record<string, string> = {}
  for (const row of extraEnv.value) {
    const name = row.name.trim()
    if (!name) continue
    out[name] = row.value
  }
  return out
}

function pickYaml() {
  selected.value = null
  customYaml.value = true
  seedYamlDrafts()
  step.value = 'configure'
}

function seedYamlDrafts() {
  const compose = extractComposeBlock(yaml.value) ?? ''
  yamlVolumes.value = parseComposeMountSlots(compose)
  yamlPorts.value = parseComposePortSlots(compose)
  yamlVolumeDirty.value = false
  yamlPortDirty.value = false
}

watch(yaml, () => {
  if (customYaml.value && step.value === 'configure' && !yamlVolumeDirty.value && !yamlPortDirty.value) {
    seedYamlDrafts()
  }
})

function addYamlVolume() {
  yamlVolumes.value = [...yamlVolumes.value, { source: '', target: '/data', readOnly: false }]
  yamlVolumeDirty.value = true
}

function removeYamlVolume(index: number) {
  yamlVolumes.value = yamlVolumes.value.filter((_, i) => i !== index)
  yamlVolumeDirty.value = true
}

function setYamlVolumeSource(index: number, value: string) {
  yamlVolumes.value = yamlVolumes.value.map((row, i) => (i === index ? { ...row, source: value } : row))
  yamlVolumeDirty.value = true
}

function setYamlVolumeTarget(index: number, value: string) {
  yamlVolumes.value = yamlVolumes.value.map((row, i) => (i === index ? { ...row, target: value } : row))
  yamlVolumeDirty.value = true
}

function setYamlVolumeReadOnly(index: number, value: boolean) {
  yamlVolumes.value = yamlVolumes.value.map((row, i) => (i === index ? { ...row, readOnly: value } : row))
  yamlVolumeDirty.value = true
}

function onYamlVolumePicked(path: string) {
  if (pickerYamlIndex.value === null) return
  setYamlVolumeSource(pickerYamlIndex.value, path)
  pickerYamlIndex.value = null
}

function addYamlPort() {
  yamlPorts.value = [...yamlPorts.value, { hostPort: 0, containerPort: 0, proto: 'tcp' }]
  yamlPortDirty.value = true
}

function removeYamlPort(index: number) {
  yamlPorts.value = yamlPorts.value.filter((_, i) => i !== index)
  yamlPortDirty.value = true
}

function setYamlPort(index: number, patch: Partial<ComposePortRow>) {
  yamlPorts.value = yamlPorts.value.map((row, i) => (i === index ? { ...row, ...patch } : row))
  yamlPortDirty.value = true
}

const yamlDraftReady = computed(() => yamlDraftIssues().length === 0)

function yamlRowEmpty(row: ComposeMountDraft | ComposePortRow): boolean {
  if ('hostPort' in row) return !row.hostPort && !row.containerPort
  return !row.source.trim() && !row.target.trim()
}

function yamlDraftIssues(): string[] {
  const issues: string[] = []
  for (const row of yamlVolumes.value) {
    if (yamlRowEmpty(row)) continue
    if (!composeMountFromDraft(row)) {
      issues.push('Volumes need a host path or volume name and an absolute container path.')
      break
    }
  }
  for (const row of yamlPorts.value) {
    if (yamlRowEmpty(row)) continue
    if (!isComposePortRow(row)) {
      issues.push('Ports need a host and container port between 1 and 65535.')
      break
    }
  }
  if (!issues.length && (yamlVolumes.value.length || yamlPorts.value.length)) {
    if (extractComposeBlock(yaml.value) === null) {
      issues.push('Add a compose block to the YAML before adding volumes or ports.')
    }
  }
  return issues
}

function applyYamlDrafts(document: string): string | null {
  const mounts = yamlVolumes.value
    .filter((row) => !yamlRowEmpty(row))
    .map((row) => composeMountFromDraft(row))
    .filter((row): row is ComposeMountDraft => row !== null)
  const ports = yamlPorts.value.filter((row) => !yamlRowEmpty(row) && isComposePortRow(row))
  if (!yamlVolumeDirty.value && !yamlPortDirty.value) {
    return ensureApplicationSharedPaths(document)
  }
  const rewritten = applyComposeDocumentDrafts(document, {
    ports: yamlPortDirty.value ? ports : undefined,
    mounts: yamlVolumeDirty.value ? mounts : undefined,
  })
  if (rewritten === null) return null
  if (yamlVolumeDirty.value) return rewritten
  return ensureApplicationSharedPaths(rewritten)
}

async function submit() {
  error.value = ''
  const device = selectedDevice.value
  if (!device) {
    error.value = `Pick a ${DEVICE_LABEL}.`
    return
  }
  if (blockedReason.value) {
    error.value = blockedReason.value
    return
  }
  if (!customYaml.value && selected.value) {
    showErrors.value = true
    const missing = applyBlockedField.value
    if (missing) {
      error.value = `${missing.label} is required`
      return
    }
  }
  if (customYaml.value && !yamlDraftReady.value) {
    error.value = yamlDraftIssues()[0] ?? 'Fix the volume or port rows first.'
    return
  }
  submitting.value = true
  try {
    let body: unknown
    let headers: Record<string, string> | undefined
    if (customYaml.value) {
      const rewritten = applyYamlDrafts(yaml.value)
      if (rewritten === null) {
        error.value = 'Could not apply the volume or port rows — edit the compose block directly.'
        submitting.value = false
        return
      }
      body = rewritten
      headers = { 'Content-Type': 'application/yaml' }
    } else if (selected.value) {
      const hostPort = Number(portOverride.value)
      body = applicationDocument(
        selected.value,
        name.value.trim() || selected.value.id,
        values.value,
        extraFolders.value,
        gpuShareVisible(gpuShare.value) ? selectedGPUIds.value : [],
        {
          enabled: openThrough.value,
          mode: resolvedMode.value,
          extraEnv: extraEnvRecord(),
          hostPort: Number.isFinite(hostPort) && hostPort > 0 ? hostPort : null,
        },
      )
    } else {
      error.value = 'Pick an app.'
      submitting.value = false
      return
    }
    void createProgress.followApp({
      name: name.value.trim() || selected.value?.id || 'App',
      body,
      headers,
      device,
    })
    emit('created')
  } catch (e: unknown) {
    error.value = apiErrorMessage(e)
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div class="mag-overlay" @click.self="emit('close')">
    <div class="mag-frame">
      <div class="mag-head">
        <h2>Create App</h2>
        <span class="mag-step">{{ step === 'gallery' ? 'Step 1 of 2' : 'Step 2 of 2' }}</span>
      </div>
      <div class="mag-body">
        <template v-if="step === 'gallery'">
          <p v-if="homeLibrary.appsError && homeLibrary.apps.length === 0" class="err">{{ homeLibrary.appsError }}</p>
          <template v-else>
            <AppGalleryToolbar v-model:query="galleryQuery" v-model:category="galleryCategory" :apps="homeLibrary.apps" />
            <p class="mag-count">{{ visibleApps.length }} of {{ homeLibrary.apps.length }} apps · {{ galleryFilterSummary }}</p>
            <div v-if="visibleApps.length === 0" class="mag-empty">No apps match your filters.</div>
            <div v-else class="mag-shelf">
              <div
                v-for="app in visibleApps"
                :key="appCatalogKey(app)"
                class="mag-card"
                @click="pickApp(app)"
              >
                <img v-if="app.iconUrl" class="mag-icon-img" :src="app.iconUrl" :alt="app.name" />
                <span v-else class="mag-ic">{{ app.name.slice(0, 1) }}</span>
                <b>{{ app.name }}</b>
                <span>{{ app.tagline || app.description || 'Application' }}</span>
                <span class="mag-meta">{{ appArchLabel(app.arches) }} · {{ appSourceLabel(app.source) }}</span>
                <span v-if="app.unsupportedReasons.length" class="mag-block">{{ app.unsupportedReasons.join(', ') }}</span>
              </div>
            </div>
          </template>
          <div class="mag-custom" @click="pickYaml">
            Use YAML
            <span class="mag-custom-hint">Hand-written Application spec</span>
          </div>
        </template>

        <template v-else>
          <p v-if="installTip && !customYaml" class="callout">{{ installTip }}</p>
          <label v-if="!customYaml" class="field">
            <span>Name</span>
            <input v-model="name" type="text" />
          </label>
          <label v-if="!customYaml" class="toggle">
            <input v-model="openThrough" type="checkbox" />
            <span>Open through BarkVisor</span>
          </label>
          <label class="field">
            <span>{{ DEVICE_LABEL }}</span>
            <select v-model="hostId">
              <option
                v-for="row in devices.devices"
                :key="row.hostId"
                :value="row.hostId"
              >{{ devices.deviceLabel(row) }}</option>
            </select>
          </label>
          <p v-if="openUIPreview" class="url-preview">{{ openUIPreview }}</p>
          <p v-if="archMismatch && selected" class="warn">
            The selected Device is {{ deviceArch || 'unknown' }}. The app needs {{ appArchLabel(selected.arches) }}.
          </p>
          <p v-if="dockerBlocked" class="warn">{{ dockerBlocked }}</p>
          <p v-if="digestLine" class="digest">{{ digestLine }}</p>
          <label v-if="customYaml" class="field">
            <span>Workload spec</span>
            <textarea v-model="yaml" spellcheck="false" />
          </label>
          <template v-if="customYaml">
            <div class="section-label">Volumes</div>
            <div v-for="(row, index) in yamlVolumes" :key="'yaml-vol-' + index" class="yaml-row">
              <input
                class="mono"
                aria-label="Host folder"
                :value="row.source"
                placeholder="Host folder"
                @input="setYamlVolumeSource(index, ($event.target as HTMLInputElement).value)"
              />
              <AppButton size="sm" @click="pickerYamlIndex = index">Choose</AppButton>
              <input
                class="mono"
                aria-label="Container path"
                :value="row.target"
                placeholder="/data"
                @input="setYamlVolumeTarget(index, ($event.target as HTMLInputElement).value)"
              />
              <label class="ro-cell">
                <input
                  type="checkbox"
                  aria-label="Read only"
                  :checked="row.readOnly"
                  @change="setYamlVolumeReadOnly(index, ($event.target as HTMLInputElement).checked)"
                />
                <span>ro</span>
              </label>
              <AppButton size="sm" @click="removeYamlVolume(index)">Remove</AppButton>
            </div>
            <button class="add-row" type="button" @click="addYamlVolume">Add volume</button>
            <div class="section-label">Ports</div>
            <div v-for="(row, index) in yamlPorts" :key="'yaml-port-' + index" class="yaml-row">
              <AppSelect
                :modelValue="row.proto"
                style="width:80px"
                @update:modelValue="setYamlPort(index, { proto: String($event) })"
              >
                <option value="tcp">TCP</option>
                <option value="udp">UDP</option>
              </AppSelect>
              <input
                class="mono"
                type="number"
                aria-label="Host port"
                :value="row.hostPort || ''"
                placeholder="Host port"
                min="1"
                max="65535"
                @input="setYamlPort(index, { hostPort: Number(($event.target as HTMLInputElement).value) })"
              />
              <span class="port-arrow">→</span>
              <input
                class="mono"
                type="number"
                aria-label="Container port"
                :value="row.containerPort || ''"
                placeholder="Container port"
                min="1"
                max="65535"
                @input="setYamlPort(index, { containerPort: Number(($event.target as HTMLInputElement).value) })"
              />
              <AppButton size="sm" @click="removeYamlPort(index)">Remove</AppButton>
            </div>
            <button class="add-row" type="button" @click="addYamlPort">Add port</button>
            <p v-if="!yamlDraftReady" class="warn">{{ yamlDraftIssues()[0] }}</p>
          </template>
          <template v-else>
            <div v-if="folderFields.length" class="section-label">Folders</div>
            <label
              v-for="field in folderFields"
              :key="field.id"
              class="field"
              :class="{ err: showErrors && fieldError(field, values) }"
            >
              <span>{{ field.label }}<em v-if="field.required"> *</em></span>
              <div class="path-row">
                <input
                  class="mono"
                  :value="values[field.id] || ''"
                  :placeholder="field.placeholder || 'Choose a folder'"
                  @input="setField(field.id, ($event.target as HTMLInputElement).value)"
                />
                <AppButton size="sm" @click="pickerFieldId = field.id">Choose</AppButton>
              </div>
              <span class="help">{{ showErrors && fieldError(field, values) ? fieldError(field, values) : field.description }}</span>
            </label>
            <div v-if="envFields.length" class="section-label">Environment</div>
            <label
              v-for="field in envFields"
              :key="field.id"
              class="field"
              :class="{ err: showErrors && fieldError(field, values) }"
            >
              <span>{{ field.label }}<em v-if="field.required"> *</em></span>
              <select
                v-if="fieldKind(field) === 'select'"
                :value="values[field.id] || ''"
                @change="setField(field.id, ($event.target as HTMLSelectElement).value)"
              >
                <option v-for="opt in field.options || []" :key="opt" :value="opt">{{ opt }}</option>
              </select>
              <input
                v-else-if="fieldKind(field) === 'bool'"
                type="checkbox"
                :checked="values[field.id] === 'true'"
                @change="setField(field.id, ($event.target as HTMLInputElement).checked ? 'true' : 'false')"
              />
              <input
                v-else
                :type="fieldKind(field) === 'number' ? 'number' : 'text'"
                :value="values[field.id] || ''"
                @input="setField(field.id, ($event.target as HTMLInputElement).value)"
              />
              <span v-if="field.description" class="help">{{ field.description }}</span>
            </label>
            <div v-if="secretFields.length" class="section-label">Secrets</div>
            <label
              v-for="field in secretFields"
              :key="field.id"
              class="field"
              :class="{ err: showErrors && fieldError(field, values) }"
            >
              <span>{{ field.label }}<em v-if="field.required"> *</em></span>
              <div class="secret-row">
                <input
                  class="mono"
                  type="password"
                  :value="values[field.id] || ''"
                  :placeholder="field.placeholder || ''"
                  @input="setField(field.id, ($event.target as HTMLInputElement).value)"
                />
                <AppButton size="sm" @click="setField(field.id, generateSecret())">Generate</AppButton>
              </div>
              <span class="help">{{ showErrors && fieldError(field, values) ? fieldError(field, values) : field.description }}</span>
              <a v-if="isClaim(field)" class="claim" href="https://plex.tv/claim" target="_blank" rel="noreferrer">Get a claim token · expires in 4 minutes</a>
            </label>
            <template v-if="gpuShareVisible(gpuShare)">
              <div class="section-label">GPUs</div>
              <label v-for="card in gpuShare" :key="card.id" class="gpu-row">
                <input
                  type="checkbox"
                  :checked="selectedGPUIds.includes(card.id)"
                  :disabled="!card.attachable"
                  @change="toggleGPU(card.id, ($event.target as HTMLInputElement).checked)"
                />
                <span>
                  <b>{{ card.label }}</b>
                  <span v-if="gpuShareOccupancy(card)" class="help">{{ gpuShareOccupancy(card) }}</span>
                </span>
              </label>
            </template>
            <div v-if="portFields.length" class="section-label">Ports</div>
            <label v-for="field in portFields" :key="field.id" class="field">
              <span>{{ field.label }}<em v-if="field.required"> *</em></span>
              <input
                type="number"
                :value="values[field.id] || ''"
                @input="setField(field.id, ($event.target as HTMLInputElement).value)"
              />
              <span v-if="field.description" class="help">{{ field.description }}</span>
            </label>
            <div class="section-label">Extra binds</div>
            <div v-for="(row, index) in extraFolders" :key="'extra-' + index" class="extra-folder">
              <input
                class="mono"
                :value="row.hostPath"
                placeholder="Host folder"
                @input="setExtraHost(index, ($event.target as HTMLInputElement).value)"
              />
              <input
                class="mono"
                :value="row.containerPath"
                placeholder="/media"
                @input="setExtraContainer(index, ($event.target as HTMLInputElement).value)"
              />
              <AppButton size="sm" @click="pickerExtraIndex = index">Choose</AppButton>
              <AppButton size="sm" @click="removeFolder(index)">Remove</AppButton>
            </div>
            <button class="add-row" type="button" @click="addFolder">Add bind</button>
            <div class="section-label">
              <button class="add-row" type="button" @click="advancedOpen = !advancedOpen">{{ advancedOpen ? 'Hide advanced' : 'Advanced' }}</button>
            </div>
            <template v-if="advancedOpen">
              <label v-for="field in advancedFields" :key="field.id" class="field">
                <span>{{ field.label }}</span>
                <input
                  :value="values[field.id] || ''"
                  @input="setField(field.id, ($event.target as HTMLInputElement).value)"
                />
              </label>
              <label class="field">
                <span>Mode</span>
                <select v-model="modeOverride">
                  <option value="">Catalog ({{ selected ? catalogProxy(selected) : 'direct' }})</option>
                  <option value="prefix">prefix</option>
                  <option value="direct">direct</option>
                </select>
              </label>
              <label class="field">
                <span>Published port override</span>
                <input v-model="portOverride" type="number" placeholder="Catalog default" />
              </label>
              <div class="section-label">Extra env</div>
              <div v-for="(row, index) in extraEnv" :key="'env-' + index" class="extra-folder">
                <input class="mono" :value="row.name" placeholder="NAME" @input="setExtraEnvName(index, ($event.target as HTMLInputElement).value)" />
                <input class="mono" :value="row.value" placeholder="value" @input="setExtraEnvValue(index, ($event.target as HTMLInputElement).value)" />
                <AppButton size="sm" @click="removeEnv(index)">Remove</AppButton>
              </div>
              <button class="add-row" type="button" @click="addEnv">Add env</button>
              <div v-if="managedKeys.length" class="section-label">Managed env</div>
              <p v-for="key in managedKeys" :key="key" class="managed">{{ key }}</p>
            </template>
          </template>
          <p v-if="error" class="err">{{ error }}</p>
          <p v-else-if="blockedReason" class="err">{{ blockedReason }}</p>
        </template>
      </div>
      <div class="mag-foot">
        <AppButton v-if="step === 'configure'" @click="step = 'gallery'">Back</AppButton>
        <AppButton v-else @click="emit('close')">Cancel</AppButton>
        <AppButton
          v-if="step === 'configure'"
          variant="primary"
          :disabled="submitting || !!blockedReason || (!customYaml && !!applyBlockedField)"
          @click="submit"
        >
          {{ submitting ? 'Applying…' : 'Apply' }}
        </AppButton>
      </div>
    </div>
    <FolderPicker
      v-if="pickerFieldId"
      :modelValue="values[pickerFieldId] || ''"
      :device="selectedDevice"
      @update:modelValue="setField(pickerFieldId, $event); pickerFieldId = null"
      @close="pickerFieldId = null"
    />
    <FolderPicker
      v-if="pickerExtraIndex !== null"
      :modelValue="extraFolders[pickerExtraIndex]?.hostPath || ''"
      :device="selectedDevice"
      @update:modelValue="onExtraPicked($event)"
      @close="pickerExtraIndex = null"
    />
    <FolderPicker
      v-if="pickerYamlIndex !== null"
      :modelValue="yamlVolumes[pickerYamlIndex]?.source || ''"
      :device="selectedDevice"
      @update:modelValue="onYamlVolumePicked($event)"
      @close="pickerYamlIndex = null"
    />
  </div>
</template>

<style scoped>
.mag-overlay {
  position: fixed;
  inset: 0;
  background: var(--modal-overlay-bg);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 20;
  padding: 24px;
}
.mag-frame {
  width: 720px;
  max-width: 100%;
  max-height: 90vh;
  background: var(--modal-surface);
  border: 1px solid var(--border);
  border-radius: 2px;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  box-shadow: var(--shadow-lg);
}
.mag-head {
  padding: 18px 22px 12px;
  border-bottom: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  align-items: baseline;
}
.mag-head h2 {
  font-size: 17px;
  font-weight: 700;
  margin: 0;
}
.mag-step { font-size: 12px; color: var(--text-dim); }
.mag-body {
  padding: 16px 22px;
  overflow: auto;
  flex: 1;
}
.mag-shelf {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 10px;
}
.mag-count {
  margin: 0 0 10px;
  font-size: 11.5px;
  color: var(--text-dim);
}
.mag-empty {
  grid-column: 1 / -1;
  text-align: center;
  color: var(--text-dim);
  padding: 40px 0;
  font-size: 12.5px;
}
.mag-card {
  border: 1px solid var(--mag-line, var(--border));
  border-radius: 2px;
  background: var(--mag-panel, var(--panel));
  padding: 16px 14px;
  cursor: pointer;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.mag-card:hover { border-color: rgba(0, 144, 248, 0.5); }
.mag-ic {
  width: 34px;
  height: 34px;
  border-radius: 8px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--accent-muted);
  color: var(--accent);
  font-weight: 700;
}
.mag-icon-img {
  width: 34px;
  height: 34px;
  border-radius: 8px;
  object-fit: cover;
}
.mag-card b { font-size: 13.5px; font-weight: 600; }
.mag-card span { font-size: 11.5px; color: var(--mag-dim, var(--text-dim)); line-height: 1.4; }
.mag-meta { font-size: 11px !important; }
.mag-block { color: var(--amber) !important; }
.mag-custom {
  margin-top: 10px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 11px 14px;
  border: 1px dashed var(--mag-line, var(--border));
  border-radius: 2px;
  color: var(--mag-dim, var(--text-dim));
  cursor: pointer;
  font-size: 12.5px;
}
.mag-custom-hint { margin-left: auto; font-size: 11px; }
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-bottom: 12px;
  font-size: 13px;
}
.field textarea,
.field select,
.field input {
  background: var(--bg-input);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 8px 10px;
}
.field textarea {
  min-height: 280px;
  font-family: var(--font-mono);
  font-size: 12px;
  line-height: 1.45;
}
.warn { color: var(--amber); font-size: 13px; }
.err { color: var(--red); font-size: 13px; }
.digest { font-size: 12px; font-family: var(--font-mono); color: var(--text-dim); }
.section-label {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--text-dim);
  font-weight: 600;
  margin: 18px 0 10px;
  padding-top: 14px;
  border-top: 1px solid var(--border);
}
.path-row, .secret-row { display: flex; gap: 8px; }
.path-row input, .secret-row input { flex: 1; }
.mono { font-family: var(--font-mono); font-size: 12px; }
.help { font-size: 11px; color: var(--text-dim); }
.field.err input { border-color: var(--red); }
.field.err .help { color: var(--red); }
.field em { color: var(--red); font-style: normal; }
.add-row {
  background: none;
  border: none;
  color: var(--accent);
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
  padding: 2px 0;
  font-family: inherit;
}
.extra-folder {
  display: grid;
  grid-template-columns: 1fr 120px auto auto;
  gap: 8px;
  margin-bottom: 8px;
}
.extra-folder input {
  background: var(--bg-input);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 8px 10px;
}
.yaml-row {
  display: flex;
  gap: 8px;
  align-items: center;
  margin-bottom: 8px;
}
.yaml-row input.mono {
  background: var(--bg-input);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 8px 10px;
  min-width: 0;
  flex: 1;
}
.yaml-row select {
  background: var(--bg-input);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 8px 6px;
}
.yaml-row .port-arrow {
  color: var(--text-dim);
  font-size: 12px;
  text-align: center;
}
.yaml-row .ro-cell {
  display: flex;
  align-items: center;
  gap: 5px;
  font-size: 12px;
  color: var(--text-dim);
  white-space: nowrap;
}
.callout {
  background: rgba(251, 191, 36, 0.08);
  border: 1px solid rgba(251, 191, 36, 0.35);
  color: var(--amber);
  font-size: 12px;
  padding: 9px 12px;
  border-radius: 2px;
  margin-bottom: 12px;
}
.url-preview {
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--green, #34d399);
  margin: 0 0 12px;
}
.claim {
  font-size: 12px;
  color: var(--accent);
}
.gpu-row {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  margin-bottom: 10px;
  font-size: 13px;
}
.gpu-row b { font-weight: 600; }
.gpu-row span { display: flex; flex-direction: column; gap: 2px; }
.mag-foot {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  padding: 12px 16px;
}
.toggle {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 12px;
  font-size: 13px;
}
.managed {
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--text-dim);
  margin: 0 0 4px;
}
</style>
