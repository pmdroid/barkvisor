<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import { useDevicesStore } from '../stores/devices'
import { useHomeLibraryStore, type HomeApp } from '../stores/homeLibrary'
import { useToastStore } from '../stores/toast'
import { useFeature } from '../composables/useFeature'
import { devicePath, isSelfDevice } from '../utils/homeDeviceApi'
import { DEVICE_LABEL } from '../utils/terminology'
import {
  appArchLabel,
  appInstallBlockedReason,
  appSupportsDeviceArch,
  applicationSpecYaml,
} from '../utils/appCatalog'
import AppButton from './ui/AppButton.vue'

const props = defineProps<{ initialHostId?: string }>()
const emit = defineEmits(['close', 'created'])

const devices = useDevicesStore()
const homeLibrary = useHomeLibraryStore()
const toast = useToastStore()
const docker = useFeature('dockerEngine')

const step = ref<'gallery' | 'configure'>('gallery')
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

onMounted(() => {
  void homeLibrary.fetchApps(devices.devices)
})

function pickApp(app: HomeApp) {
  selected.value = app
  customYaml.value = false
  name.value = app.id
  step.value = 'configure'
}

function pickYaml() {
  selected.value = null
  customYaml.value = true
  step.value = 'configure'
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
  const body = customYaml.value
    ? yaml.value
    : selected.value
      ? applicationSpecYaml(selected.value, name.value.trim() || selected.value.id)
      : ''
  if (!body.trim()) {
    error.value = 'Pick an app.'
    return
  }
  submitting.value = true
  try {
    await api.post(devicePath(device, '/workloads/apply'), body, {
      headers: { 'Content-Type': 'application/yaml' },
    })
    toast.success('App applied')
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
          <div v-else class="mag-shelf">
            <div
              v-for="app in homeLibrary.apps"
              :key="app.id"
              class="mag-card"
              @click="pickApp(app)"
            >
              <img v-if="app.iconUrl" class="mag-icon-img" :src="app.iconUrl" :alt="app.name" />
              <span v-else class="mag-ic">{{ app.name.slice(0, 1) }}</span>
              <b>{{ app.name }}</b>
              <span>{{ app.tagline || app.description || 'Application' }}</span>
              <span class="mag-meta">{{ appArchLabel(app.arches) }} · {{ app.source }}</span>
              <span v-if="app.unsupportedReasons.length" class="mag-block">{{ app.unsupportedReasons.join(', ') }}</span>
            </div>
          </div>
          <div class="mag-custom" @click="pickYaml">
            Use YAML
            <span class="mag-custom-hint">Hand-written Application spec</span>
          </div>
        </template>

        <template v-else>
          <label v-if="!customYaml" class="field">
            <span>Name</span>
            <input v-model="name" type="text" />
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
          <p v-if="archMismatch && selected" class="warn">
            The selected Device is {{ deviceArch || 'unknown' }}. The app needs {{ appArchLabel(selected.arches) }}.
          </p>
          <p v-if="dockerBlocked" class="warn">{{ dockerBlocked }}</p>
          <p v-if="digestLine" class="digest">{{ digestLine }}</p>
          <label v-if="customYaml" class="field">
            <span>Workload spec</span>
            <textarea v-model="yaml" spellcheck="false" />
          </label>
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
          :disabled="submitting || !!blockedReason"
          @click="submit"
        >
          {{ submitting ? 'Applying…' : 'Apply' }}
        </AppButton>
      </div>
    </div>
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
.mag-foot {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  padding: 12px 16px;
}
</style>
