<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import { apiErrorMessage } from '../api/errors'
import api from '../api/client'
import type { TaskAcceptedResponse, UpdateCheckResponse, UpdateInfo, UpdateSettings } from '../api/types'
import { useTaskPoller } from '../composables/useTaskPoller'
import { useFeature } from '../composables/useFeature'
import { useToastStore } from '../stores/toast'
import { useDevicesStore } from '../stores/devices'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import {
  canCallDeviceAPI,
  deviceAboutPath,
  deviceHealthPath,
  deviceTaskPath,
  deviceUpdateCheckPath,
  deviceUpdateInstallPath,
  deviceUpdateSettingsPath,
  resolveSelectedDevice,
} from '../utils/homeDeviceApi'
import { pollUntilHealthy } from '../utils/updateHealthPoll'
import AppButton from './ui/AppButton.vue'
import AppSelect from './ui/AppSelect.vue'
import ConfirmDialog from './ConfirmDialog.vue'
import UnsupportedHint from './ui/UnsupportedHint.vue'

const toast = useToastStore()
const devices = useDevicesStore()
const inAppUpdate = useFeature('inAppUpdate')
const selectedHostId = ref('')
const currentVersion = ref('')
const availableUpdate = ref<UpdateInfo | null>(null)
const updateSettings = ref<UpdateSettings>({
  channel: 'stable',
  autoCheck: false,
  isDevBuild: false,
  updateURL: null,
})
const checkingUpdate = ref(false)
const installConfirm = ref(false)
const updatePhase = ref<'idle' | 'installing' | 'restarting' | 'success' | 'error'>('idle')
const updateError = ref('')
const { task: updateTask, poll: pollTask, stop: stopPoll } = useTaskPoller()

const selectedDevice = computed(() =>
  resolveSelectedDevice(selectedHostId.value, devices.deviceByHostId, devices.selfDevice),
)
const selectedDeviceReachable = computed(() =>
  selectedDevice.value != null && canCallDeviceAPI(selectedDevice.value),
)
const deviceOptions = computed(() => devices.devices.map((device) => ({
  value: device.hostId,
  label: device.role === 'self' ? `${deviceDisplayLabel(device)} (Local Device)` : deviceDisplayLabel(device),
  disabled: !canCallDeviceAPI(device),
})))

function resetForDevice() {
  stopPoll()
  currentVersion.value = ''
  availableUpdate.value = null
  updateSettings.value = {
    channel: 'stable', autoCheck: false, isDevBuild: false, updateURL: null,
  }
  checkingUpdate.value = false
  installConfirm.value = false
  updatePhase.value = 'idle'
  updateError.value = ''
  updateTask.value = null
}

function selectedTarget() {
  const device = selectedDevice.value
  return device && canCallDeviceAPI(device) ? device : null
}

function isCurrentDevice(device: { hostId: string }): boolean {
  return selectedDevice.value?.hostId === device.hostId
}

async function fetchUpdateSettings() {
  const device = selectedTarget()
  if (!device) return
  try {
    const { data } = await api.get<UpdateSettings>(deviceUpdateSettingsPath(device))
    if (isCurrentDevice(device)) updateSettings.value = data
  } catch {
    // Fail closed on a non-appliance Device.
  }
}

async function saveUpdateSettings() {
  const device = selectedTarget()
  if (!device) return
  try {
    const { data } = await api.put<UpdateSettings>(deviceUpdateSettingsPath(device), updateSettings.value)
    if (isCurrentDevice(device)) {
      updateSettings.value = data
      toast.success('Update settings saved')
    }
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  }
}

async function checkForUpdates() {
  const device = selectedTarget()
  if (!device) return
  checkingUpdate.value = true
  try {
    const { data } = await api.get<UpdateCheckResponse>(deviceUpdateCheckPath(device))
    if (!isCurrentDevice(device)) return
    currentVersion.value = data.currentVersion
    availableUpdate.value = data.update
    if (!data.update) toast.success('Already on the latest version')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    if (isCurrentDevice(device)) checkingUpdate.value = false
  }
}

async function loadUpdates() {
  if (inAppUpdate.available && selectedTarget()) {
    await fetchUpdateSettings()
    await checkForUpdates()
  }
}

async function doInstallUpdate() {
  installConfirm.value = false
  const device = selectedTarget()
  const update = availableUpdate.value
  if (!device || !update) return
  updatePhase.value = 'installing'
  updateError.value = ''
  try {
    const { data } = await api.post<TaskAcceptedResponse>(deviceUpdateInstallPath(device), {
      version: update.version,
    })
    await pollTask(data.taskID, {
      interval: 1500,
      path: deviceTaskPath(device, data.taskID),
      onComplete: () => {
        if (isCurrentDevice(device)) void startHealthPoll(device)
      },
      onFailed: (event) => {
        if (!isCurrentDevice(device)) return
        updatePhase.value = 'error'
        updateError.value = event.error || 'Update failed'
      },
    })
  } catch {
    if (isCurrentDevice(device)) void startHealthPoll(device)
  }
}

async function startHealthPoll(device: NonNullable<typeof selectedDevice.value>) {
  if (!isCurrentDevice(device)) return
  updatePhase.value = 'restarting'
  const result = await pollUntilHealthy({
    health: async () => {
      const { status } = await api.get(deviceHealthPath(device))
      return status === 200
    },
  })
  if (result === 'timeout') {
    if (!isCurrentDevice(device)) return
    updatePhase.value = 'error'
    updateError.value =
      'Timed out waiting for /api/health. Refresh in a minute.'
    return
  }
  try {
    const { data } = await api.get<{ version?: string }>(deviceAboutPath(device))
    if (isCurrentDevice(device) && data.version) currentVersion.value = data.version
  } catch {
    // Health already passed.
  }
  if (isCurrentDevice(device)) {
    availableUpdate.value = null
    updatePhase.value = 'success'
  }
}

function resetUpdateState() {
  updatePhase.value = 'idle'
  updateError.value = ''
}

function reloadPage() {
  window.location.reload()
}

watch(() => devices.selfDevice?.hostId, (hostId) => {
  if (!selectedHostId.value && hostId) selectedHostId.value = hostId
}, { immediate: true })

watch(selectedHostId, () => {
  resetForDevice()
  void loadUpdates()
})

onUnmounted(() => {
  stopPoll()
})

void devices.fetchHealth()
</script>

<template>
  <div v-if="!inAppUpdate.available" class="update-status-card">
    <div class="update-title">In-app updates unavailable</div>
    <UnsupportedHint :text="inAppUpdate.explanation" />
  </div>
  <div v-else>
    <div class="update-target">
      <label for="update-device">Device</label>
      <AppSelect
        id="update-device"
        :model-value="selectedHostId"
        :options="deviceOptions"
        @update:model-value="selectedHostId = $event"
      />
      <p v-if="selectedDevice && !selectedDeviceReachable" class="update-target-error">
        Selected Device is unreachable. Updates are unavailable until it reconnects.
      </p>
    </div>

    <div v-if="updatePhase === 'success'" class="update-status-card update-success">
      <div class="update-title">Updated successfully</div>
      <p class="update-copy">Now running v{{ currentVersion }}.</p>
      <AppButton variant="primary" @click="reloadPage">Reload page</AppButton>
    </div>

    <div v-else-if="updatePhase === 'restarting'" class="update-status-card">
      <div class="update-title">Restarting…</div>
      <p class="update-copy">Waiting for /api/health. Workloads stay up.</p>
      <div class="progress-bar">
        <div class="progress-bar-fill progress-bar-indeterminate"></div>
      </div>
    </div>

    <div v-else-if="updatePhase === 'installing'" class="update-status-card">
      <div class="update-title">Installing update…</div>
      <p class="update-copy">Downloading and verifying v{{ availableUpdate?.version }}. Keep this page open.</p>
      <div class="progress-bar">
        <div class="progress-bar-fill" :style="{ width: ((updateTask?.progress ?? 0) * 100) + '%' }"></div>
      </div>
    </div>

    <div v-else-if="updatePhase === 'error'" class="update-status-card update-error">
      <div class="update-title">Update failed</div>
      <p class="update-copy">{{ updateError }}</p>
      <AppButton @click="resetUpdateState">Dismiss</AppButton>
    </div>

    <template v-else>
      <div class="update-toolbar">
        <p class="update-copy">
          Current version: <strong>v{{ currentVersion || '…' }}</strong>
        </p>
        <AppButton
          variant="primary"
          :loading="checkingUpdate"
          loading-text="Checking…"
          :disabled="!selectedDeviceReachable"
          @click="checkForUpdates"
        >Check for updates</AppButton>
      </div>

      <div v-if="availableUpdate" class="update-card">
        <div class="update-toolbar">
          <div>
            <h3 class="update-heading">v{{ availableUpdate.version }} available</h3>
            <span class="update-meta">
              Released {{ new Date(availableUpdate.publishedAt).toLocaleDateString() }}
              · {{ availableUpdate.packageKind }}
            </span>
            <span v-if="availableUpdate.isPrerelease" class="badge badge-yellow">Pre-release</span>
          </div>
          <AppButton variant="primary" :disabled="!selectedDeviceReachable" @click="installConfirm = true">Install update</AppButton>
        </div>
        <div v-if="availableUpdate.changelog" class="changelog">
          <p class="changelog-label">Changelog</p>
          <pre>{{ availableUpdate.changelog }}</pre>
        </div>
      </div>

      <div class="update-prefs">
        <h3 class="update-heading">Update preferences</h3>
        <div class="form-group">
          <label>Channel</label>
          <AppSelect
            :model-value="updateSettings.channel"
            :disabled="!selectedDeviceReachable"
            @update:model-value="updateSettings.channel = $event as 'stable' | 'beta'; saveUpdateSettings()"
          >
            <option value="stable">Stable</option>
            <option value="beta">Beta (includes pre-releases)</option>
          </AppSelect>
        </div>
        <div v-if="updateSettings.isDevBuild" class="form-group">
          <label>Test update URL</label>
          <input
            :value="updateSettings.updateURL ?? ''"
            :disabled="!selectedDeviceReachable"
            placeholder="https://api.github.com/repos/owner/repo/releases"
            @change="updateSettings.updateURL = ($event.target as HTMLInputElement).value || null; saveUpdateSettings()"
          />
        </div>
      </div>
    </template>
  </div>

  <ConfirmDialog
    v-if="installConfirm && availableUpdate"
    title="Install update"
    :message="`Install v${availableUpdate.version}? The daemon restarts; Workloads stay up.`"
    confirm-label="Install"
    @confirm="doInstallUpdate"
    @cancel="installConfirm = false"
  />
</template>

<style scoped>
.update-toolbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  margin-bottom: 20px;
}
.update-target {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 20px;
}
.update-target label {
  color: var(--text-secondary);
  font-size: 13px;
  font-weight: 600;
}
.update-target-error {
  color: var(--red, #ef4444);
  font-size: 13px;
  margin: 0;
}
.update-card,
.update-status-card {
  background: var(--bg-raised, var(--bg));
  border: 1px solid var(--border);
  border-radius: var(--radius, 8px);
  padding: 24px;
}
.update-status-card {
  text-align: center;
}
.update-success {
  border-color: var(--green, #22c55e);
}
.update-error {
  border-color: var(--red, #ef4444);
}
.update-title {
  font-size: 20px;
  margin-bottom: 8px;
}
.update-heading {
  margin: 0 0 4px;
  font-size: 16px;
}
.update-copy,
.update-meta {
  color: var(--text-secondary);
  font-size: 13px;
  margin: 0 0 12px;
}
.update-prefs {
  margin-top: 24px;
  padding-top: 20px;
  border-top: 1px solid var(--border);
}
.changelog {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius-xs, 6px);
  padding: 12px;
}
.changelog-label {
  font-size: 12px;
  color: var(--text-secondary);
  margin: 0 0 6px;
  font-weight: 500;
}
.changelog pre {
  white-space: pre-wrap;
  font-size: 12px;
  color: var(--text-secondary);
  margin: 0;
  max-height: 200px;
  overflow-y: auto;
}
.progress-bar {
  height: 6px;
  background: var(--bg);
  border-radius: 3px;
  overflow: hidden;
  margin-top: 16px;
}
.progress-bar-fill {
  height: 100%;
  background: var(--accent);
  border-radius: 3px;
}
.progress-bar-indeterminate {
  width: 30%;
  animation: indeterminate 1.5s ease-in-out infinite;
}
@keyframes indeterminate {
  0% { transform: translateX(-100%); }
  100% { transform: translateX(400%); }
}
.badge-yellow {
  background: var(--yellow-muted, rgba(234, 179, 8, 0.15));
  color: var(--yellow, #eab308);
  margin-left: 8px;
}
.form-group input {
  width: 100%;
  max-width: 500px;
}
</style>
