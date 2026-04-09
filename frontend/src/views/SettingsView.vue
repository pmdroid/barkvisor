<script setup lang="ts">
import { ref, onMounted, onUnmounted, computed } from 'vue'
import api from '../api/client'
import type { APIKeyResponse, AuditEntry, SSHKey, UpdateCheckResponse, UpdateSettings, UpdateInfo } from '../api/types'
import { useToastStore } from '../stores/toast'
import { useSSHKeyStore } from '../stores/sshKeys'
import { useTaskPoller } from '../composables/useTaskPoller'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'

const toast = useToastStore()
const sshKeyStore = useSSHKeyStore()
const tab = ref<'apikeys' | 'sshkeys' | 'audit' | 'updates'>('apikeys')

// API Keys
const apiKeys = ref<APIKeyResponse[]>([])
const showCreate = ref(false)
const newKeyName = ref('')
const newKeyExpiry = ref('90d')
const createLoading = ref(false)
const createdKey = ref<string | null>(null)
const copied = ref(false)

async function fetchKeys() {
  const { data } = await api.get('/auth/keys')
  apiKeys.value = data
}

async function createKey() {
  if (!newKeyName.value.trim()) return
  createLoading.value = true
  try {
    const { data } = await api.post('/auth/keys', {
      name: newKeyName.value.trim(),
      expiresIn: newKeyExpiry.value,
    })
    createdKey.value = data.key
    newKeyName.value = ''
    await fetchKeys()
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    createLoading.value = false
  }
}

function copyKey() {
  if (createdKey.value) {
    navigator.clipboard.writeText(createdKey.value)
    copied.value = true
    setTimeout(() => (copied.value = false), 2000)
  }
}

function closeCreatedKey() {
  createdKey.value = null
  showCreate.value = false
}

const revokeTarget = ref<APIKeyResponse | null>(null)
const revoking = ref(false)

async function doRevoke() {
  if (!revokeTarget.value) return
  revoking.value = true
  try {
    await api.delete(`/auth/keys/${revokeTarget.value.id}`)
    await fetchKeys()
    toast.success('API key revoked')
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    revoking.value = false
    revokeTarget.value = null
  }
}

// SSH Keys
const showAddSSHKey = ref(false)
const newSSHKeyName = ref('')
const newSSHKeyPublicKey = ref('')
const addSSHKeyLoading = ref(false)
const deleteSSHKeyTarget = ref<SSHKey | null>(null)
const deletingSSHKey = ref(false)

async function addSSHKey() {
  if (!newSSHKeyName.value.trim() || !newSSHKeyPublicKey.value.trim()) return
  addSSHKeyLoading.value = true
  try {
    await sshKeyStore.create(newSSHKeyName.value.trim(), newSSHKeyPublicKey.value.trim())
    toast.success('SSH key added')
    newSSHKeyName.value = ''
    newSSHKeyPublicKey.value = ''
    showAddSSHKey.value = false
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    addSSHKeyLoading.value = false
  }
}

async function setSSHKeyDefault(id: string) {
  try {
    await sshKeyStore.setDefault(id)
    toast.success('Default SSH key updated')
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  }
}

async function doDeleteSSHKey() {
  if (!deleteSSHKeyTarget.value) return
  deletingSSHKey.value = true
  try {
    await sshKeyStore.remove(deleteSSHKeyTarget.value.id)
    toast.success('SSH key deleted')
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    deletingSSHKey.value = false
    deleteSSHKeyTarget.value = null
  }
}

// Audit Log
const auditEntries = ref<AuditEntry[]>([])
const auditTotal = ref(0)
const auditPage = ref(0)
const auditLoading = ref(false)
const auditFilter = ref('')
const pageSize = 25

async function fetchAudit() {
  auditLoading.value = true
  try {
    const params: Record<string, string | number> = {
      limit: pageSize,
      offset: auditPage.value * pageSize,
    }
    if (auditFilter.value) params.action = auditFilter.value
    const { data } = await api.get('/audit-log', { params })
    auditEntries.value = data.entries
    auditTotal.value = data.total
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    auditLoading.value = false
  }
}

const totalPages = computed(() => Math.max(1, Math.ceil(auditTotal.value / pageSize)))

function prevPage() {
  if (auditPage.value > 0) { auditPage.value--; fetchAudit() }
}
function nextPage() {
  if (auditPage.value < totalPages.value - 1) { auditPage.value++; fetchAudit() }
}

function applyFilter(action: string) {
  auditFilter.value = action
  auditPage.value = 0
  fetchAudit()
}

function formatDate(iso: string) {
  return new Date(iso).toLocaleString()
}

function expiryLabel(expiresAt: string | null) {
  if (!expiresAt) return 'Never'
  const d = new Date(expiresAt)
  if (d < new Date()) return 'Expired'
  return d.toLocaleDateString()
}

function expiryClass(expiresAt: string | null) {
  if (!expiresAt) return 'badge-gray'
  return new Date(expiresAt) < new Date() ? 'badge-red' : 'badge-gray'
}

const actionColors: Record<string, string> = {
  create: 'badge-green',
  start: 'badge-green',
  login: 'badge-blue',
  update: 'badge-blue',
  resize: 'badge-blue',
  stop: 'badge-yellow',
  restart: 'badge-yellow',
  delete: 'badge-red',
  revoke: 'badge-red',
}

function actionBadgeClass(action: string) {
  const verb = action.split('.')[1] || action
  return actionColors[verb] || 'badge-gray'
}


// Updates
const currentVersion = ref('')
const availableUpdate = ref<UpdateInfo | null>(null)
const updateSettings = ref<UpdateSettings>({ channel: 'stable', autoCheck: false, isDevBuild: false, updateURL: null })
const checkingUpdate = ref(false)
const installConfirm = ref(false)
const updatePhase = ref<'idle' | 'installing' | 'restarting' | 'success' | 'error'>('idle')
const updateError = ref('')
const { task: updateTask, poll: pollTask, stop: stopPoll } = useTaskPoller()
let healthPollTimer: ReturnType<typeof setTimeout> | null = null

async function fetchUpdateSettings() {
  try {
    const { data } = await api.get('/system/updates/settings')
    updateSettings.value = data
  } catch {}
}

async function saveUpdateSettings() {
  try {
    const { data } = await api.put('/system/updates/settings', updateSettings.value)
    updateSettings.value = data
    toast.success('Update settings saved')
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  }
}

async function checkForUpdates() {
  checkingUpdate.value = true
  try {
    const { data } = await api.get<UpdateCheckResponse>('/system/updates/check')
    currentVersion.value = data.currentVersion
    availableUpdate.value = data.update
    if (!data.update) {
      toast.success('You are running the latest version')
    }
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    checkingUpdate.value = false
  }
}

async function doInstallUpdate() {
  installConfirm.value = false
  const update = availableUpdate.value
  if (!update) return

  updatePhase.value = 'installing'
  updateError.value = ''

  try {
    const { data } = await api.post('/system/updates/install', {
      version: update.version,
    })

    await pollTask(data.taskID, {
      interval: 1500,
      onComplete: () => startHealthPoll(update.version),
      onFailed: (event) => {
        updatePhase.value = 'error'
        updateError.value = event.error || 'Update failed'
      },
    })
  } catch {
    // Connection likely dropped because the server is restarting
    startHealthPoll(update.version)
  }
}

function startHealthPoll(_expectedVersion: string) {
  updatePhase.value = 'restarting'
  let elapsed = 0
  let serverSeen = false
  const interval = 2000
  const timeout = 120000
  // After the server responds with the same version, wait a bit in case
  // it's the old process still shutting down, then accept the update.
  const sameVersionGrace = 10000

  const check = async () => {
    elapsed += interval
    if (elapsed > timeout) {
      updatePhase.value = 'error'
      updateError.value = 'Timed out waiting for server to restart. The update may still be in progress — try refreshing the page in a minute.'
      return
    }
    try {
      const { data } = await api.get('/system/about')
      if (data.version && data.version !== currentVersion.value) {
        // Version changed — update definitely succeeded
        currentVersion.value = data.version
        availableUpdate.value = null
        updatePhase.value = 'success'
        return
      }
      if (!serverSeen) {
        // Server is back but version unchanged — start grace timer
        serverSeen = true
        healthPollTimer = setTimeout(() => {
          // Server survived restart with same version string — accept it
          currentVersion.value = data.version ?? currentVersion.value
          availableUpdate.value = null
          updatePhase.value = 'success'
        }, sameVersionGrace)
        return
      }
    } catch {
      // Server not back yet — reset grace if it was a transient blip
      serverSeen = false
    }
    healthPollTimer = setTimeout(check, interval)
  }
  healthPollTimer = setTimeout(check, interval)
}

function reloadPage() {
  window.location.reload()
}

function resetUpdateState() {
  updatePhase.value = 'idle'
  updateError.value = ''
}

onMounted(() => {
  fetchKeys()
})

onUnmounted(() => {
  stopPoll()
  if (healthPollTimer) clearTimeout(healthPollTimer)
})
</script>

<template>
  <div class="page-header">
    <h1>Settings</h1>
  </div>

  <div class="tabs">
    <button :class="{ active: tab === 'apikeys' }" @click="tab = 'apikeys'">API Keys</button>
    <button :class="{ active: tab === 'sshkeys' }" @click="tab = 'sshkeys'; sshKeyStore.fetchAll()">SSH Keys</button>
    <button :class="{ active: tab === 'audit' }" @click="tab = 'audit'; fetchAudit()">Audit Log</button>
    <button :class="{ active: tab === 'updates' }" @click="tab = 'updates'; fetchUpdateSettings(); checkForUpdates()">Updates</button>
  </div>

  <!-- API Keys Tab -->
  <div v-if="tab === 'apikeys'">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
      <p style="color:var(--text-secondary);font-size:13px;margin:0">
        API keys allow external tools to authenticate with BarkVisor. The key is shown only once on creation.
      </p>
      <AppButton variant="primary" icon="plus" @click="showCreate = true; createdKey = null">Create Key</AppButton>
    </div>

    <EmptyState v-if="apiKeys.length === 0" icon="key" title="No API keys yet. Create one to allow external tools to access BarkVisor." />

    <DataTable v-else :columns="[{ key: 'name', label: 'Name' }, { key: 'key', label: 'Key' }, { key: 'expires', label: 'Expires' }, { key: 'lastUsed', label: 'Last Used' }, { key: 'created', label: 'Created' }, { key: 'actions', label: '', align: 'right' }]">
          <tr v-for="k in apiKeys" :key="k.id">
            <td style="font-weight:500">{{ k.name }}</td>
            <td class="mono" style="color:var(--text-secondary)">{{ k.keyPrefix }}...</td>
            <td><span class="badge" :class="expiryClass(k.expiresAt)">{{ expiryLabel(k.expiresAt) }}</span></td>
            <td style="color:var(--text-secondary)">{{ k.lastUsedAt ? formatDate(k.lastUsedAt) : 'Never' }}</td>
            <td style="color:var(--text-secondary)">{{ formatDate(k.createdAt) }}</td>
            <td style="text-align:right">
              <AppButton size="sm" style="color:var(--red)" @click="revokeTarget = k">Revoke</AppButton>
            </td>
          </tr>
    </DataTable>
  </div>

  <!-- SSH Keys Tab -->
  <div v-if="tab === 'sshkeys'">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
      <p style="color:var(--text-secondary);font-size:13px;margin:0">
        SSH public keys are automatically injected into cloud image VMs via cloud-init.
      </p>
      <AppButton variant="primary" icon="plus" @click="showAddSSHKey = true">Add Key</AppButton>
    </div>

    <EmptyState v-if="sshKeyStore.keys.length === 0" icon="key" title="No SSH keys yet. Add one to use with cloud image VMs." />

    <DataTable v-else :columns="[{ key: 'name', label: 'Name' }, { key: 'type', label: 'Type' }, { key: 'fingerprint', label: 'Fingerprint' }, { key: 'created', label: 'Created' }, { key: 'actions', label: '', align: 'right' }]">
          <tr v-for="k in sshKeyStore.keys" :key="k.id">
            <td style="font-weight:500">
              {{ k.name }}
              <span v-if="k.isDefault" class="badge badge-green" style="margin-left:6px">default</span>
            </td>
            <td><span class="badge badge-gray">{{ k.keyType }}</span></td>
            <td class="mono" style="color:var(--text-secondary);font-size:11px">{{ k.fingerprint }}</td>
            <td style="color:var(--text-secondary)">{{ formatDate(k.createdAt) }}</td>
            <td style="white-space:nowrap;text-align:right">
              <div style="display:flex;gap:4px;justify-content:flex-end">
                <AppButton v-if="!k.isDefault" size="sm" @click="setSSHKeyDefault(k.id)">Set Default</AppButton>
                <AppButton size="sm" style="color:var(--red)" @click="deleteSSHKeyTarget = k">Delete</AppButton>
              </div>
            </td>
          </tr>
    </DataTable>
  </div>

  <!-- Add SSH Key Modal -->
  <div v-if="showAddSSHKey" class="modal-overlay" @click.self="showAddSSHKey = false">
    <div class="modal">
      <h2>Add SSH Key</h2>
      <div class="form-group">
        <label>Name</label>
        <input v-model="newSSHKeyName" placeholder="e.g. macbook, ci-server" />
      </div>
      <div class="form-group">
        <label>Public Key</label>
        <textarea
          v-model="newSSHKeyPublicKey"
          placeholder="ssh-ed25519 AAAA... user@host"
          rows="3"
          style="font-family:var(--font-mono);font-size:12px;resize:vertical"
        />
      </div>
      <div class="modal-actions">
        <AppButton @click="showAddSSHKey = false">Cancel</AppButton>
        <AppButton variant="primary" :disabled="!newSSHKeyName.trim() || !newSSHKeyPublicKey.trim()" :loading="addSSHKeyLoading" loadingText="Adding..." @click="addSSHKey">Add Key</AppButton>
      </div>
    </div>
  </div>

  <!-- Delete SSH Key Confirm -->
  <ConfirmDialog
    v-if="deleteSSHKeyTarget"
    title="Delete SSH Key"
    :message="`Delete SSH key &quot;${deleteSSHKeyTarget.name}&quot;? This will not affect VMs that were already created with this key.`"
    confirm-label="Delete"
    :danger="true"
    :loading="deletingSSHKey"
    @confirm="doDeleteSSHKey"
    @cancel="deleteSSHKeyTarget = null"
  />

  <!-- Audit Log Tab -->
  <div v-if="tab === 'audit'">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
      <p style="color:var(--text-secondary);font-size:13px;margin:0">
        Activity log of all actions performed via the API. Entries older than 90 days are automatically pruned.
      </p>
      <AppSelect :modelValue="auditFilter" @update:modelValue="applyFilter($event)">
        <option value="">All Actions</option>
        <optgroup label="VM">
          <option value="vm.create">vm.create</option>
          <option value="vm.deploy">vm.deploy</option>
          <option value="vm.start">vm.start</option>
          <option value="vm.stop">vm.stop</option>
          <option value="vm.restart">vm.restart</option>
          <option value="vm.update">vm.update</option>
          <option value="vm.delete">vm.delete</option>
          <option value="vm.attach-iso">vm.attach-iso</option>
        </optgroup>
        <optgroup label="Disk">
          <option value="disk.create">disk.create</option>
          <option value="disk.resize">disk.resize</option>
          <option value="disk.delete">disk.delete</option>
        </optgroup>
        <optgroup label="Network">
          <option value="network.create">network.create</option>
          <option value="network.update">network.update</option>
          <option value="network.delete">network.delete</option>
        </optgroup>
        <optgroup label="API Key">
          <option value="apikey.create">apikey.create</option>
          <option value="apikey.revoke">apikey.revoke</option>
        </optgroup>
        <optgroup label="SSH Key">
          <option value="ssh-key.create">ssh-key.create</option>
          <option value="ssh-key.delete">ssh-key.delete</option>
        </optgroup>
        <optgroup label="System">
          <option value="app.start">app.start</option>
          <option value="app.stop">app.stop</option>
        </optgroup>
      </AppSelect>
    </div>

    <div v-if="auditLoading && auditEntries.length === 0" class="empty">
      <p>Loading...</p>
    </div>

    <div v-else-if="auditEntries.length === 0" class="empty">
      <p>No audit log entries{{ auditFilter ? ' matching filter' : '' }}.</p>
    </div>

    <template v-else>
      <DataTable :columns="[{ key: 'time', label: 'Time' }, { key: 'user', label: 'User' }, { key: 'action', label: 'Action' }, { key: 'resource', label: 'Resource' }, { key: 'auth', label: 'Auth' }]">
            <tr v-for="e in auditEntries" :key="e.id">
              <td style="white-space:nowrap;color:var(--text-secondary)">{{ formatDate(e.timestamp) }}</td>
              <td>{{ e.username || '-' }}</td>
              <td>
                <button class="badge" :class="actionBadgeClass(e.action)" style="cursor:pointer;border:none" @click="applyFilter(e.action)">
                  {{ e.action }}
                </button>
              </td>
              <td>
                <span v-if="e.resourceName" style="font-weight:500">{{ e.resourceName }}</span>
                <span v-else-if="e.resourceId" class="mono" style="color:var(--text-secondary)">{{ e.resourceId.slice(0, 8) }}...</span>
                <span v-else style="color:var(--text-dim)">-</span>
              </td>
              <td><span class="badge badge-gray">{{ e.authMethod || '-' }}</span></td>
            </tr>
      </DataTable>

      <div style="display:flex;justify-content:space-between;align-items:center;margin-top:12px">
        <span style="font-size:12px;color:var(--text-secondary)">{{ auditTotal }} entries</span>
        <div style="display:flex;gap:8px;align-items:center">
          <AppButton size="sm" :disabled="auditPage === 0" @click="prevPage">Prev</AppButton>
          <span style="font-size:12px;color:var(--text-secondary)">{{ auditPage + 1 }} / {{ totalPages }}</span>
          <AppButton size="sm" :disabled="auditPage >= totalPages - 1" @click="nextPage">Next</AppButton>
        </div>
      </div>
    </template>
  </div>

  <!-- Updates Tab -->
  <div v-if="tab === 'updates'">
    <!-- Success state -->
    <div v-if="updatePhase === 'success'" class="update-status-card update-success">
      <div style="font-size:20px;margin-bottom:8px">Updated successfully</div>
      <p style="color:var(--text-secondary);margin-bottom:16px">BarkVisor has been updated to v{{ currentVersion }}.</p>
      <AppButton variant="primary" @click="reloadPage">Reload Page</AppButton>
    </div>

    <!-- Restarting state -->
    <div v-else-if="updatePhase === 'restarting'" class="update-status-card">
      <div style="font-size:20px;margin-bottom:8px">Restarting server...</div>
      <p style="color:var(--text-secondary)">The update has been installed. Waiting for the server to come back online...</p>
      <div class="progress-bar" style="margin-top:16px">
        <div class="progress-bar-fill progress-bar-indeterminate"></div>
      </div>
    </div>

    <!-- Installing state -->
    <div v-else-if="updatePhase === 'installing'" class="update-status-card">
      <div style="font-size:20px;margin-bottom:8px">Installing update...</div>
      <p style="color:var(--text-secondary);margin-bottom:12px">Downloading and verifying v{{ availableUpdate?.version }}. Do not close this page.</p>
      <div class="progress-bar">
        <div class="progress-bar-fill" :style="{ width: ((updateTask?.progress ?? 0) * 100) + '%' }"></div>
      </div>
      <p v-if="updateTask?.progress" style="color:var(--text-secondary);font-size:12px;margin-top:8px;text-align:center">
        {{ Math.round((updateTask.progress ?? 0) * 100) }}%
      </p>
    </div>

    <!-- Error state -->
    <div v-else-if="updatePhase === 'error'" class="update-status-card update-error">
      <div style="font-size:20px;margin-bottom:8px">Update failed</div>
      <p style="color:var(--text-secondary);margin-bottom:16px">{{ updateError }}</p>
      <AppButton @click="resetUpdateState">Dismiss</AppButton>
    </div>

    <!-- Normal state -->
    <template v-else>
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
        <div>
          <p style="color:var(--text-secondary);font-size:13px;margin:0">
            Current version: <strong style="color:var(--text)">v{{ currentVersion || '...' }}</strong>
          </p>
        </div>
        <AppButton variant="primary" :loading="checkingUpdate" loadingText="Checking..." @click="checkForUpdates">Check for Updates</AppButton>
      </div>

      <!-- Update available -->
      <div v-if="availableUpdate" class="update-card">
        <div style="display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:12px">
          <div>
            <h3 style="margin:0 0 4px 0">v{{ availableUpdate.version }} available</h3>
            <span style="color:var(--text-secondary);font-size:12px">
              Released {{ new Date(availableUpdate.publishedAt).toLocaleDateString() }}
            </span>
            <span v-if="availableUpdate.isPrerelease" class="badge badge-yellow" style="margin-left:8px">Pre-release</span>
          </div>
          <AppButton variant="primary" @click="installConfirm = true">Install Update</AppButton>
        </div>
        <div v-if="availableUpdate.changelog" class="changelog">
          <p style="font-size:12px;color:var(--text-secondary);margin:0 0 6px 0;font-weight:500">Changelog</p>
          <pre style="white-space:pre-wrap;font-size:12px;color:var(--text-secondary);margin:0;max-height:200px;overflow-y:auto">{{ availableUpdate.changelog }}</pre>
        </div>
      </div>

      <!-- Settings -->
      <div style="margin-top:24px;padding-top:20px;border-top:1px solid var(--border)">
        <h3 style="margin:0 0 12px 0;font-size:14px">Update Preferences</h3>
        <div style="display:flex;gap:16px;align-items:center">
          <div class="form-group" style="margin:0">
            <label style="font-size:12px;margin-bottom:4px">Channel</label>
            <AppSelect :modelValue="updateSettings.channel" @update:modelValue="updateSettings.channel = $event as 'stable' | 'beta'; saveUpdateSettings()">
              <option value="stable">Stable</option>
              <option value="beta">Beta (includes pre-releases)</option>
            </AppSelect>
          </div>
        </div>
        <div style="margin-top:12px">
          <div class="form-group" style="margin:0">
            <label style="font-size:12px;margin-bottom:4px">Test Update URL <span style="color:var(--text-tertiary)">(dev only)</span></label>
            <input
              :value="updateSettings.updateURL ?? ''"
              @change="updateSettings.updateURL = ($event.target as HTMLInputElement).value || null; saveUpdateSettings()"
              placeholder="https://api.github.com/repos/owner/repo/releases"
              style="width:100%;max-width:500px"
            />
          </div>
        </div>
      </div>
    </template>
  </div>

  <!-- Install Update Confirm -->
  <ConfirmDialog
    v-if="installConfirm"
    title="Install Update"
    :message="`Install BarkVisor v${availableUpdate?.version}? The server will restart and all connections will drop briefly.`"
    confirm-label="Install"
    :danger="false"
    :loading="false"
    @confirm="doInstallUpdate"
    @cancel="installConfirm = false"
  />

  <!-- Create Key Modal -->
  <div v-if="showCreate" class="modal-overlay" @click.self="closeCreatedKey">
    <div class="modal">
      <template v-if="!createdKey">
        <h2>Create API Key</h2>
        <div class="form-group">
          <label>Name</label>
          <input v-model="newKeyName" placeholder="e.g. terraform, ci-pipeline" />
        </div>
        <div class="form-group">
          <label>Expires</label>
          <AppSelect v-model="newKeyExpiry">
            <option value="30d">30 days</option>
            <option value="90d">90 days</option>
            <option value="1y">1 year</option>
            <option value="never">Never</option>
          </AppSelect>
        </div>
        <div class="modal-actions">
          <AppButton @click="showCreate = false">Cancel</AppButton>
          <AppButton variant="primary" :disabled="!newKeyName.trim()" :loading="createLoading" loadingText="Creating..." @click="createKey">Create</AppButton>
        </div>
      </template>
      <template v-else>
        <h2>API Key Created</h2>
        <p style="color:var(--text-secondary);font-size:13px;margin-bottom:16px">
          Copy this key now. It will not be shown again.
        </p>
        <div style="background:var(--bg);border:1px solid var(--border);border-radius:var(--radius-xs);padding:12px;font-family:var(--font-mono);font-size:12px;word-break:break-all;user-select:all">
          {{ createdKey }}
        </div>
        <div class="modal-actions" style="margin-top:16px">
          <AppButton variant="primary" @click="copyKey">{{ copied ? 'Copied!' : 'Copy to Clipboard' }}</AppButton>
          <AppButton @click="closeCreatedKey">Done</AppButton>
        </div>
      </template>
    </div>
  </div>

  <!-- Revoke Confirm -->
  <ConfirmDialog
    v-if="revokeTarget"
    title="Revoke API Key"
    :message="`Revoke key &quot;${revokeTarget.name}&quot; (${revokeTarget.keyPrefix}...)? Any tools using this key will lose access immediately.`"
    confirm-label="Revoke"
    :danger="true"
    :loading="revoking"
    @confirm="doRevoke"
    @cancel="revokeTarget = null"
  />
</template>

<style scoped>
.tabs {
  display: flex;
  gap: 4px;
  margin-bottom: 24px;
}
.tabs button {
  padding: 6px 14px;
  background: transparent;
  border: none;
  border-radius: var(--radius-xs, 6px);
  color: var(--text-secondary);
  cursor: pointer;
  font-size: 13px;
  font-weight: 500;
}
.tabs button.active {
  background: var(--accent);
  color: var(--accent-text, #fff);
}
.tabs button:hover:not(.active) {
  color: var(--text);
}
.badge-yellow { background: var(--yellow-muted, rgba(234,179,8,0.15)); color: var(--yellow, #eab308); }

.update-card {
  background: var(--bg-raised, var(--bg));
  border: 1px solid var(--border);
  border-radius: var(--radius, 8px);
  padding: 16px;
}
.changelog {
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius-xs, 6px);
  padding: 12px;
}
.update-status-card {
  background: var(--bg-raised, var(--bg));
  border: 1px solid var(--border);
  border-radius: var(--radius, 8px);
  padding: 32px;
  text-align: center;
}
.update-success {
  border-color: var(--green, #22c55e);
}
.update-error {
  border-color: var(--red, #ef4444);
}
.progress-bar {
  height: 6px;
  background: var(--bg);
  border-radius: 3px;
  overflow: hidden;
}
.progress-bar-fill {
  height: 100%;
  background: var(--accent);
  border-radius: 3px;
  transition: width 0.3s ease;
}
.progress-bar-indeterminate {
  width: 30%;
  animation: indeterminate 1.5s ease-in-out infinite;
}
@keyframes indeterminate {
  0% { transform: translateX(-100%); }
  100% { transform: translateX(400%); }
}
</style>
