<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref, onMounted, onUnmounted, computed, watch } from 'vue'
import { useRoute } from 'vue-router'
import api from '../api/client'
import type { APIKeyResponse, AuditEntry, LibrarySettings, RemoteAccessStatus, SSHKey, UpdateCheckResponse, UpdateSettings, UpdateInfo } from '../api/types'
import { useToastStore } from '../stores/toast'
import { useSSHKeyStore } from '../stores/sshKeys'
import { useTaskPoller } from '../composables/useTaskPoller'
import { useFeature } from '../composables/useFeature'
import {
  advertisedHostForOffer,
  CUSTOM_ADVERTISED_HOST,
  getPairingCode,
  issuePairingCode,
  issuedAdvertisedHost,
  joinHome,
  isPairingPayload,
  revokePairingCode,
  type PairingIssue,
} from '../api/pairing'
import {
  getLoginOffer,
  issueLoginOffer,
  revokeLoginOffer,
  type LoginOffer,
} from '../api/loginOffer'
import { loginOfferSvg } from '../utils/qrSvg'
import {
  beginTOTPSetup,
  confirmTOTPSetup,
  disableTOTP,
  getTOTPStatus,
  regenerateRecoveryCodes,
  type TOTPSetup,
  type TOTPStatus,
} from '../api/totp'
import { useDevicesStore } from '../stores/devices'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'
import {
  isCurrentPairingSeq,
  isPairingOfferActive,
  nextPairingLoadSeq,
  pairingExpiryLabel,
} from '../utils/pairingOffer'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import FolderPicker from '../components/FolderPicker.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import PairingQr from '../components/PairingQr.vue'
import UnsupportedHint from '../components/ui/UnsupportedHint.vue'

const route = useRoute()
const toast = useToastStore()
const sshKeyStore = useSSHKeyStore()
const inAppUpdate = useFeature('inAppUpdate')
const tab = ref<'home' | 'library' | 'security' | 'apikeys' | 'sshkeys' | 'audit' | 'updates'>('apikeys')

const pairingOffer = ref<PairingIssue | null>(null)
const pairingLoading = ref(false)
const pairingHydrating = ref(false)
const pairingSeq = ref(0)
const pairingNow = ref(Date.now())
const pairingCopied = ref(false)
const loginOffer = ref<LoginOffer | null>(null)
const loginOfferSvgMarkup = ref('')
const loginOfferLoading = ref(false)
const loginOfferCopied = ref(false)
const loginOfferSeq = ref(0)
const selectedHost = ref('')
const customHost = ref('')
const rejoinPayload = ref('')
const rejoinLoading = ref(false)
let pairingTick: ReturnType<typeof setInterval> | null = null

const hostOptions = computed(() => {
  const hosts = pairingOffer.value?.advertisedHosts ?? []
  return [
    ...hosts.map((host) => ({ value: host, label: host })),
    { value: CUSTOM_ADVERTISED_HOST, label: 'Other / DNS name…' },
  ]
})

function syncPickerFromOffer(offer: PairingIssue | null) {
  if (!offer) {
    selectedHost.value = ''
    customHost.value = ''
    return
  }
  const host = issuedAdvertisedHost(offer)
  if (host && offer.advertisedHosts.includes(host)) {
    selectedHost.value = host
    customHost.value = ''
    return
  }
  selectedHost.value = CUSTOM_ADVERTISED_HOST
  customHost.value = host ?? ''
}

function startPairingTick() {
  if (pairingTick != null) return
  pairingNow.value = Date.now()
  pairingTick = setInterval(() => {
    pairingNow.value = Date.now()
  }, 1000)
}

function stopPairingTick() {
  if (pairingTick == null) return
  clearInterval(pairingTick)
  pairingTick = null
}

watch([pairingOffer, loginOffer], ([pairing, login]) => {
  if (pairing || login) startPairingTick()
  else stopPairingTick()
})

async function loadPairingCode() {
  const seq = nextPairingLoadSeq(pairingLoading.value, pairingSeq.value)
  if (seq == null) return
  pairingSeq.value = seq
  pairingHydrating.value = true
  try {
    const loaded = await getPairingCode()
    if (!isCurrentPairingSeq(seq, pairingSeq.value)) return
    pairingOffer.value = loaded
    syncPickerFromOffer(loaded)
  } catch (e: unknown) {
    if (!isCurrentPairingSeq(seq, pairingSeq.value)) return
    toast.error(apiErrorMessage(e))
  } finally {
    if (isCurrentPairingSeq(seq, pairingSeq.value)) pairingHydrating.value = false
  }
}

function openHomeTab() {
  tab.value = 'home'
  loadPairingCode()
  loadLoginOffer()
  fetchLibrarySettings()
  fetchRemoteAccess()
  devicesStore.fetchHealth()
}

async function loadLoginOffer() {
  const seq = ++loginOfferSeq.value
  try {
    const loaded = await getLoginOffer()
    if (seq !== loginOfferSeq.value) return
    loginOffer.value = loaded
    await renderLoginOfferQr(seq)
  } catch (e: unknown) {
    if (seq !== loginOfferSeq.value) return
    toast.error(apiErrorMessage(e))
  }
}

async function renderLoginOfferQr(seq: number) {
  const offer = loginOffer.value
  if (!offer) {
    if (seq === loginOfferSeq.value) loginOfferSvgMarkup.value = ''
    return
  }
  const uri = offer.uri
  const svg = await loginOfferSvg(uri)
  if (seq !== loginOfferSeq.value) return
  if (loginOffer.value?.uri !== uri) return
  loginOfferSvgMarkup.value = svg
}

async function showLoginQr() {
  const host = advertisedHostForOffer(selectedHost.value, customHost.value)
  if (selectedHost.value === CUSTOM_ADVERTISED_HOST && !host) {
    toast.error(`Enter a DNS name or IP the phone can reach.`)
    return
  }
  const seq = ++loginOfferSeq.value
  loginOfferLoading.value = true
  try {
    const issued = await issueLoginOffer(host)
    if (seq !== loginOfferSeq.value) return
    loginOffer.value = issued
    await renderLoginOfferQr(seq)
  } catch (e: unknown) {
    if (seq !== loginOfferSeq.value) return
    toast.error(apiErrorMessage(e))
  } finally {
    if (seq === loginOfferSeq.value) loginOfferLoading.value = false
  }
}

async function hideLoginQr() {
  const seq = ++loginOfferSeq.value
  loginOfferLoading.value = true
  try {
    await revokeLoginOffer()
    if (seq !== loginOfferSeq.value) return
    loginOffer.value = null
    loginOfferSvgMarkup.value = ''
  } catch (e: unknown) {
    if (seq !== loginOfferSeq.value) return
    toast.error(apiErrorMessage(e))
  } finally {
    if (seq === loginOfferSeq.value) loginOfferLoading.value = false
  }
}

async function copyLoginUri() {
  if (!loginOffer.value) return
  try {
    await navigator.clipboard.writeText(loginOffer.value.uri)
    loginOfferCopied.value = true
    setTimeout(() => {
      loginOfferCopied.value = false
    }, 2000)
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not copy sign-in URI'))
  }
}

async function issueOffer(advertisedHost?: string, success?: string) {
  pairingSeq.value += 1
  const seq = pairingSeq.value
  pairingHydrating.value = false
  pairingLoading.value = true
  try {
    const issued = await issuePairingCode(advertisedHost)
    if (!isCurrentPairingSeq(seq, pairingSeq.value)) return
    pairingOffer.value = issued
    syncPickerFromOffer(issued)
    if (success) toast.success(success)
  } catch (e: unknown) {
    if (!isCurrentPairingSeq(seq, pairingSeq.value)) return
    toast.error(apiErrorMessage(e))
    if (advertisedHost !== undefined) {
      pairingOffer.value = null
    }
    syncPickerFromOffer(pairingOffer.value)
  } finally {
    if (isCurrentPairingSeq(seq, pairingSeq.value)) pairingLoading.value = false
  }
}

async function addDevice() {
  await issueOffer(undefined, `Add a ${DEVICE_LABEL} with this pairing code`)
}

function onAdvertisedHostChange(value: string) {
  selectedHost.value = value
  if (value === CUSTOM_ADVERTISED_HOST) return
  const current = pairingOffer.value ? issuedAdvertisedHost(pairingOffer.value) : null
  if (value === current) return
  void issueOffer(value, 'New pairing code for this address')
}

async function applyCustomHost() {
  const host = customHost.value.trim()
  if (!host) {
    toast.error(`Enter a DNS name or IP the new ${DEVICE_LABEL} can reach.`)
    return
  }
  const current = pairingOffer.value ? issuedAdvertisedHost(pairingOffer.value) : null
  if (host === current) return
  await issueOffer(host, 'New pairing code for this address')
}

async function revokeDeviceCode() {
  pairingSeq.value += 1
  pairingHydrating.value = false
  pairingLoading.value = true
  try {
    await revokePairingCode()
    pairingOffer.value = null
    syncPickerFromOffer(null)
    toast.success('Pairing code revoked')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    pairingLoading.value = false
  }
}

async function copyPairingPayload() {
  if (!pairingOffer.value) return
  try {
    await navigator.clipboard.writeText(pairingOffer.value.qrPayload)
    pairingCopied.value = true
    setTimeout(() => {
      pairingCopied.value = false
    }, 2000)
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not copy pairing code'))
  }
}

async function rejoinThisDevice() {
  const payload = rejoinPayload.value.trim()
  if (!isPairingPayload(payload)) {
    toast.error('Paste the full pairing code (starts with barkvisor://), not only the short code.')
    return
  }
  rejoinLoading.value = true
  try {
    await joinHome(payload)
    rejoinPayload.value = ''
    toast.success(`Trust restored. This ${DEVICE_LABEL} still runs if peers are unreachable.`)
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, `Could not re-pair this ${DEVICE_LABEL}`))
  } finally {
    rejoinLoading.value = false
  }
}

function openUpdatesTab() {
  tab.value = 'updates'
  if (inAppUpdate.available) {
    fetchUpdateSettings()
    checkForUpdates()
  }
}

function openLibraryTab() {
  tab.value = 'library'
  fetchLibrarySettings()
  devicesStore.fetchHealth()
}

const devicesStore = useDevicesStore()
const librarySettings = ref<LibrarySettings>({
  imageDirectory: '',
  isDefault: true,
  libraryDepotHostId: null,
})
const libraryDraft = ref('')
const libraryLoading = ref(false)
const librarySaving = ref(false)
const showLibraryPicker = ref(false)
const depotDraft = ref('')
const depotSaving = ref(false)

const remoteAccess = ref<RemoteAccessStatus | null>(null)
const remoteAccessLoading = ref(false)
const remoteAccessSaving = ref(false)
const advertiseDraft = ref('')
const requireTailnetDraft = ref(false)

async function fetchRemoteAccess() {
  remoteAccessLoading.value = true
  try {
    const { data } = await api.get<RemoteAccessStatus>('/system/remote-access')
    remoteAccess.value = data
    advertiseDraft.value = data.advertiseUrl ?? ''
    requireTailnetDraft.value = data.requireTailnetForRemote
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not load remote access'))
  } finally {
    remoteAccessLoading.value = false
  }
}

async function saveRemoteAccess() {
  if (!remoteAccess.value) return
  remoteAccessSaving.value = true
  try {
    const { data } = await api.put<RemoteAccessStatus>('/home/settings/remote-access', {
      requireTailnetForRemote: requireTailnetDraft.value,
      advertiseUrl: advertiseDraft.value,
    })
    remoteAccess.value = data
    advertiseDraft.value = data.advertiseUrl ?? ''
    requireTailnetDraft.value = data.requireTailnetForRemote
    toast.success('Remote access saved')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not save remote access'))
  } finally {
    remoteAccessSaving.value = false
  }
}

const depotOptions = computed(() => {
  const none = { value: '', label: 'None — download from the internet' }
  const devices = devicesStore.devices.map((device) => {
    const name = deviceDisplayLabel(device)
    const self = device.role === 'self' ? ` (this ${DEVICE_LABEL})` : ''
    const reach = device.reachability === 'ok' ? '' : ' — unreachable'
    return { value: device.hostId, label: `${name}${self}${reach}` }
  })
  return [none, ...devices]
})

async function fetchLibrarySettings() {
  libraryLoading.value = true
  try {
    const { data } = await api.get<LibrarySettings>('/system/library/settings')
    librarySettings.value = data
    libraryDraft.value = data.imageDirectory
    depotDraft.value = data.libraryDepotHostId ?? ''
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    libraryLoading.value = false
  }
}

async function saveLibrarySettings() {
  librarySaving.value = true
  try {
    const { data } = await api.put<LibrarySettings>('/system/library/settings', {
      imageDirectory: libraryDraft.value,
    })
    librarySettings.value = data
    libraryDraft.value = data.imageDirectory
    depotDraft.value = data.libraryDepotHostId ?? ''
    toast.success('Library path saved')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    librarySaving.value = false
  }
}

async function resetLibrarySettings() {
  librarySaving.value = true
  try {
    const { data } = await api.put<LibrarySettings>('/system/library/settings', {
      imageDirectory: '',
    })
    librarySettings.value = data
    libraryDraft.value = data.imageDirectory
    depotDraft.value = data.libraryDepotHostId ?? ''
    toast.success('Library path reset to the default')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    librarySaving.value = false
  }
}

async function saveDepotSettings() {
  depotSaving.value = true
  try {
    const { data } = await api.put<LibrarySettings>('/system/library/settings', {
      libraryDepotHostId: depotDraft.value,
    })
    librarySettings.value = data
    depotDraft.value = data.libraryDepotHostId ?? ''
    toast.success('Library depot saved')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    depotSaving.value = false
  }
}

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
    toast.error(apiErrorMessage(e))
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
    toast.error(apiErrorMessage(e))
  } finally {
    revoking.value = false
    revokeTarget.value = null
  }
}

const totpStatus = ref<TOTPStatus | null>(null)
const totpSetup = ref<TOTPSetup | null>(null)
const totpCode = ref('')
const totpPassword = ref('')
const recoveryCodes = ref<string[]>([])
const totpLoading = ref(false)
const totpCopied = ref(false)

async function loadTOTP() {
  try {
    totpStatus.value = await getTOTPStatus()
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  }
}

async function openSecurityTab() {
  tab.value = 'security'
  await loadTOTP()
}

async function startTOTP() {
  totpLoading.value = true
  totpCode.value = ''
  recoveryCodes.value = []
  try {
    totpSetup.value = await beginTOTPSetup()
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    totpLoading.value = false
  }
}

async function confirmTOTP() {
  if (!totpCode.value.trim()) return
  totpLoading.value = true
  try {
    recoveryCodes.value = await confirmTOTPSetup(totpCode.value.trim())
    totpSetup.value = null
    totpCode.value = ''
    await loadTOTP()
    toast.success('Two-factor authentication is on')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    totpLoading.value = false
  }
}

async function turnOffTOTP() {
  if (!totpPassword.value || !totpCode.value.trim()) return
  totpLoading.value = true
  try {
    await disableTOTP(totpPassword.value, totpCode.value.trim())
    totpPassword.value = ''
    totpCode.value = ''
    recoveryCodes.value = []
    await loadTOTP()
    toast.success('Two-factor authentication is off')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    totpLoading.value = false
  }
}

async function newRecoveryCodes() {
  if (!totpCode.value.trim()) return
  totpLoading.value = true
  try {
    recoveryCodes.value = await regenerateRecoveryCodes(totpCode.value.trim())
    totpCode.value = ''
    await loadTOTP()
    toast.success('New recovery codes generated')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    totpLoading.value = false
  }
}

function copyRecoveryCodes() {
  if (!recoveryCodes.value.length) return
  void navigator.clipboard.writeText(recoveryCodes.value.join('\n'))
  totpCopied.value = true
  setTimeout(() => (totpCopied.value = false), 2000)
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
    toast.error(apiErrorMessage(e))
  } finally {
    addSSHKeyLoading.value = false
  }
}

async function setSSHKeyDefault(id: string) {
  try {
    await sshKeyStore.setDefault(id)
    toast.success('Default SSH key updated')
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  }
}

async function doDeleteSSHKey() {
  if (!deleteSSHKeyTarget.value) return
  deletingSSHKey.value = true
  try {
    await sshKeyStore.remove(deleteSSHKeyTarget.value.id)
    toast.success('SSH key deleted')
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
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
    toast.error(apiErrorMessage(e))
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
    toast.error(apiErrorMessage(e))
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
    toast.error(apiErrorMessage(e))
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
  if (route.query.tab === 'home') openHomeTab()
})

onUnmounted(() => {
  stopPoll()
  stopPairingTick()
  if (healthPollTimer) clearTimeout(healthPollTimer)
})
</script>

<template>
  <div class="page-header">
    <h1>Settings</h1>
  </div>

  <div class="tabs">
    <button :class="{ active: tab === 'home' }" @click="openHomeTab">{{ HOME_LABEL }}</button>
    <button :class="{ active: tab === 'library' }" @click="openLibraryTab">Library</button>
    <button :class="{ active: tab === 'security' }" @click="openSecurityTab">Sign-in</button>
    <button :class="{ active: tab === 'apikeys' }" @click="tab = 'apikeys'">API Keys</button>
    <button :class="{ active: tab === 'sshkeys' }" @click="tab = 'sshkeys'; sshKeyStore.fetchAll()">SSH Keys</button>
    <button :class="{ active: tab === 'audit' }" @click="tab = 'audit'; fetchAudit()">Audit Log</button>
    <button
      :class="{ active: tab === 'updates' }"
      @click="openUpdatesTab"
    >Updates</button>
  </div>

  <!-- Home / Add a Device (PAS-51) — existing /api/pairing/codes, not a second wizard -->
  <div v-if="tab === 'home'">
    <div class="pairing-card" style="margin-bottom:16px;text-align:left">
      <h3 class="login-offer-title">Remote access</h3>
      <p class="pairing-hint" style="text-align:left;margin:0 0 12px">
        LAN works without a VPN. For off-LAN, install
        <a href="https://tailscale.com/download" target="_blank" rel="noopener">Tailscale</a>
        on this {{ DEVICE_LABEL }} and the phone or laptop. BarkVisor does not bundle Tailscale.
        Pairing and sign-in QRs use the advertise URL, then the tailnet address, then a LAN IP
        as <code>host=</code>.
      </p>
      <p v-if="remoteAccess?.tailscale.available" class="pairing-hint" style="text-align:left;margin:0 0 12px">
        Tailscale is up
        <span v-if="remoteAccess.tailscale.ip"> — {{ remoteAccess.tailscale.ip }}</span>
        <span v-if="remoteAccess.tailscale.dnsName"> ({{ remoteAccess.tailscale.dnsName }})</span>
      </p>
      <p v-else class="pairing-hint" style="text-align:left;margin:0 0 12px">
        Tailscale is not detected. Install tailscaled, sign in, then reload this page.
      </p>
      <p class="pairing-hint" style="text-align:left;margin:0 0 12px">
        WireGuard:
        {{ remoteAccess?.wireguard.configured ? 'a tunnel interface is present' : 'not detected' }}.
        BarkVisor does not configure WireGuard. If you run your own tunnel, put that address in
        the advertise URL.
      </p>
      <div class="form-group" style="margin:0 0 12px;text-align:left">
        <label for="advertise-url">Advertise URL</label>
        <input
          id="advertise-url"
          v-model="advertiseDraft"
          class="pairing-input"
          type="text"
          placeholder="hostname, MagicDNS, or tailnet IP"
          autocomplete="off"
          spellcheck="false"
          :disabled="!remoteAccess || remoteAccessLoading || remoteAccessSaving"
        />
      </div>
      <label class="pairing-hint" style="display:flex;gap:8px;align-items:center;text-align:left;margin:0 0 12px">
        <input
          type="checkbox"
          v-model="requireTailnetDraft"
          :disabled="!remoteAccess || remoteAccessLoading || remoteAccessSaving"
          style="width:16px;height:16px;cursor:pointer"
        />
        Require Tailscale (or LAN) for the Home API off this network
      </label>
      <div style="display:flex;justify-content:flex-end">
        <AppButton
          size="sm"
          variant="primary"
          :loading="remoteAccessSaving"
          :disabled="!remoteAccess || remoteAccessLoading"
          @click="saveRemoteAccess"
        >
          Save remote access
        </AppButton>
      </div>
    </div>
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
      <p style="color:var(--text-secondary);font-size:13px;margin:0">
        Add a {{ DEVICE_LABEL }} to this {{ HOME_LABEL }}. On the new {{ DEVICE_LABEL }}, open
        setup and choose Join an existing {{ HOME_LABEL }}, then scan the QR or paste this pairing code.
      </p>
      <AppButton
        variant="primary"
        icon="plus"
        :disabled="pairingHydrating"
        :loading="pairingLoading"
        loading-text="Creating..."
        @click="addDevice"
      >
        Add a {{ DEVICE_LABEL }}
      </AppButton>
    </div>

    <EmptyState
      v-if="!pairingOffer"
      icon="key"
      :title="`No pairing code yet. Add a ${DEVICE_LABEL} to invite another machine into this ${HOME_LABEL}.`"
    />

    <div v-else class="pairing-card">
      <ol class="pairing-steps">
        <li>Pick the address the new {{ DEVICE_LABEL }} can reach (LAN IP or DNS name).</li>
        <li>Scan the QR or copy the full <code>barkvisor://</code> offer, not only the short code.</li>
        <li>
          On the new {{ DEVICE_LABEL }}, choose Join an existing {{ HOME_LABEL }} or run
          <code>barkvisor join --code</code>.
        </li>
        <li>The offer expires. Revoke it if you are not going to use it.</li>
      </ol>
      <div class="pairing-host">
        <label for="pairing-advertised-host">Address in this offer</label>
        <AppSelect
          :modelValue="selectedHost"
          :options="hostOptions"
          :disabled="pairingLoading"
          @update:modelValue="onAdvertisedHostChange"
        />
        <div v-if="selectedHost === CUSTOM_ADVERTISED_HOST" class="pairing-custom">
          <input
            v-model="customHost"
            class="pairing-input"
            type="text"
            placeholder="hostname or DNS name"
            autocomplete="off"
            spellcheck="false"
            :disabled="pairingLoading"
            @keydown.enter.prevent="applyCustomHost"
          />
          <AppButton size="sm" :loading="pairingLoading" @click="applyCustomHost">
            Use this address
          </AppButton>
        </div>
      </div>
      <div class="pairing-code">{{ pairingOffer.code }}</div>
      <PairingQr
        v-if="isPairingOfferActive(pairingOffer.expiresAt, pairingNow)"
        :key="pairingOffer.qrPayload"
        :payload="pairingOffer.qrPayload"
      />
      <p class="pairing-meta">{{ pairingExpiryLabel(pairingOffer.expiresAt, pairingNow) }}</p>
      <p class="pairing-hint">
        Changing the address issues a new code and offer. This
        {{ DEVICE_LABEL }} still runs if that {{ DEVICE_LABEL }} is unreachable.
      </p>
      <pre class="pairing-uri">{{ pairingOffer.qrPayload }}</pre>
      <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:12px">
        <AppButton size="sm" @click="copyPairingPayload">
          {{ pairingCopied ? 'Copied' : 'Copy pairing code' }}
        </AppButton>
        <AppButton size="sm" style="color:var(--red)" :loading="pairingLoading" @click="revokeDeviceCode">
          Revoke
        </AppButton>
      </div>
    </div>

    <div class="pairing-card login-offer-card">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
        <div>
          <h3 class="login-offer-title">Phone sign-in</h3>
          <p class="pairing-hint" style="text-align:left;margin:0">
            Sign in on the iPhone app. This is not pairing. Scan the QR in BarkVisor, or open
            the sign-in URI if the system Camera launched the app.
          </p>
        </div>
        <AppButton
          size="sm"
          variant="primary"
          :loading="loginOfferLoading"
          @click="showLoginQr"
        >
          Show sign-in QR
        </AppButton>
      </div>
      <div v-if="loginOffer" class="login-offer-body">
        <div class="login-offer-qr" v-html="loginOfferSvgMarkup" />
        <p class="pairing-meta">{{ pairingExpiryLabel(loginOffer.expiresAt, pairingNow) }}</p>
        <pre class="pairing-uri">{{ loginOffer.uri }}</pre>
        <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:12px">
          <AppButton size="sm" @click="copyLoginUri">
            {{ loginOfferCopied ? 'Copied' : 'Copy URI' }}
          </AppButton>
          <AppButton size="sm" style="color:var(--red)" :loading="loginOfferLoading" @click="hideLoginQr">
            Hide
          </AppButton>
        </div>
      </div>
    </div>

    <div class="pairing-card rejoin-card">
      <p class="pairing-hint" style="text-align:left;margin:0 0 10px">
        If this {{ DEVICE_LABEL }} already has its data, paste a pairing code from
        another {{ DEVICE_LABEL }} to restore trust. Local workloads keep running.
      </p>
      <textarea
        v-model="rejoinPayload"
        class="pairing-input"
        rows="3"
        placeholder="barkvisor://pair/v1?…"
        autocomplete="off"
        spellcheck="false"
      />
      <div style="display:flex;justify-content:flex-end;margin-top:12px">
        <AppButton
          size="sm"
          variant="primary"
          :loading="rejoinLoading"
          loading-text="Re-pairing..."
          @click="rejoinThisDevice"
        >
          Re-pair this {{ DEVICE_LABEL }}
        </AppButton>
      </div>
    </div>

    <div class="pairing-card" style="margin-top:16px">
      <p class="pairing-hint" style="text-align:left;margin:0 0 10px">
        Catalog Download writes into this {{ DEVICE_LABEL }}’s Library. Other
        {{ DEVICE_LABEL }}s fetch from it first. If that {{ DEVICE_LABEL }} is
        down or the checksum does not match, they download from the internet.
        Starting a Workload on this {{ DEVICE_LABEL }} never waits on the Library depot.
      </p>
      <div class="form-group" style="margin:0;text-align:left">
        <label>Library depot</label>
        <AppSelect
          :modelValue="depotDraft"
          :options="depotOptions"
          :disabled="libraryLoading || depotSaving"
          @update:modelValue="depotDraft = $event"
        />
      </div>
      <div style="display:flex;justify-content:flex-end;margin-top:12px">
        <AppButton
          size="sm"
          variant="primary"
          :loading="depotSaving"
          loading-text="Saving..."
          :disabled="libraryLoading"
          @click="saveDepotSettings"
        >
          Save Library depot
        </AppButton>
      </div>
    </div>
  </div>

  <!-- Two-factor (PAS-86). API keys stay on their own tab. -->
  <div v-if="tab === 'security'">
    <div class="pairing-card" style="margin-bottom:16px">
      <h3 style="margin:0 0 8px">Two-factor authentication</h3>
      <p class="pairing-hint" style="text-align:left;margin:0 0 12px">
        Require an authenticator app after the password when signing in to this Device.
        API keys are not affected. Phone sign-in QR codes still work once you are already signed in.
      </p>
      <p v-if="totpStatus?.enabled" class="pairing-hint" style="text-align:left;margin:0 0 12px">
        On. {{ totpStatus.recoveryCodesRemaining }} recovery codes remaining.
      </p>
      <p v-else class="pairing-hint" style="text-align:left;margin:0 0 12px">Off.</p>
      <AppButton
        v-if="!totpStatus?.enabled && !totpSetup"
        variant="primary"
        :loading="totpLoading"
        @click="startTOTP"
      >
        Enable authenticator
      </AppButton>
    </div>

    <div v-if="totpSetup" class="pairing-card" style="margin-bottom:16px">
      <p class="pairing-hint" style="text-align:left;margin:0 0 12px">
        Scan this QR in your authenticator app, or enter the secret, then confirm with a code.
      </p>
      <PairingQr v-if="totpSetup.otpauthUrl" :payload="totpSetup.otpauthUrl" />
      <p class="mono" style="font-size:13px;word-break:break-all;margin:12px 0">{{ totpSetup.secret }}</p>
      <div class="form-group" style="text-align:left">
        <label>Authenticator code</label>
        <input v-model="totpCode" type="text" inputmode="numeric" autocomplete="one-time-code" placeholder="123456" />
      </div>
      <AppButton variant="primary" :loading="totpLoading" :disabled="!totpCode.trim()" @click="confirmTOTP">
        Confirm
      </AppButton>
    </div>

    <div v-if="recoveryCodes.length" class="pairing-card" style="margin-bottom:16px">
      <p class="pairing-hint" style="text-align:left;margin:0 0 12px">
        Save these recovery codes. Each one works once if you lose the authenticator.
      </p>
      <pre class="mono" style="text-align:left;font-size:13px;line-height:1.6">{{ recoveryCodes.join('\n') }}</pre>
      <AppButton size="sm" @click="copyRecoveryCodes">{{ totpCopied ? 'Copied!' : 'Copy codes' }}</AppButton>
    </div>

    <div v-if="totpStatus?.enabled" class="pairing-card">
      <div class="form-group" style="text-align:left">
        <label>Authenticator or recovery code</label>
        <input v-model="totpCode" type="text" autocomplete="one-time-code" />
      </div>
      <div class="form-group" style="text-align:left">
        <label>Password (required to turn off)</label>
        <input v-model="totpPassword" type="password" />
      </div>
      <div style="display:flex;gap:8px;flex-wrap:wrap">
        <AppButton size="sm" :loading="totpLoading" :disabled="!totpCode.trim()" @click="newRecoveryCodes">
          New recovery codes
        </AppButton>
        <AppButton
          size="sm"
          variant="danger"
          :loading="totpLoading"
          :disabled="!totpPassword || !totpCode.trim()"
          @click="turnOffTOTP"
        >
          Turn off two-factor
        </AppButton>
      </div>
    </div>
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
        SSH public keys live on Home and are automatically injected into cloud image VMs via cloud-init.
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

  <!-- Library Tab -->
  <div v-if="tab === 'library'">
    <p style="color:var(--text-secondary);font-size:13px;margin:0 0 16px 0">
      Directory used for <strong>new</strong> image downloads and uploads on this
      {{ DEVICE_LABEL }}. Existing Library images are not migrated.
    </p>
    <div class="form-group" style="max-width:640px">
      <label>Library path</label>
      <div style="display:flex;gap:8px;align-items:center">
        <input
          v-model="libraryDraft"
          :disabled="libraryLoading || librarySaving"
          placeholder="/var/lib/barkvisor/images"
          style="flex:1"
        />
        <AppButton size="sm" :disabled="libraryLoading || librarySaving" @click="showLibraryPicker = true">
          Browse
        </AppButton>
      </div>
      <p style="color:var(--text-tertiary);font-size:12px;margin:8px 0 0 0">
        {{ librarySettings.isDefault ? 'Using the default path on this Device.' : 'Using a custom Library path.' }}
        Absolute path required. Must be writable by the daemon and must not contain a comma.
      </p>
    </div>
    <div style="display:flex;gap:8px;margin-top:16px">
      <AppButton
        variant="primary"
        :loading="librarySaving"
        loading-text="Saving..."
        :disabled="libraryLoading"
        @click="saveLibrarySettings"
      >
        Save
      </AppButton>
      <AppButton
        :disabled="libraryLoading || librarySaving || librarySettings.isDefault"
        @click="resetLibrarySettings"
      >
        Reset to default
      </AppButton>
    </div>
    <FolderPicker
      v-if="showLibraryPicker"
      :model-value="libraryDraft"
      @update:model-value="libraryDraft = $event"
      @close="showLibraryPicker = false"
    />
  </div>

  <!-- Updates Tab -->
  <div v-if="tab === 'updates' && !inAppUpdate.available" class="update-status-card">
    <div style="font-size:20px;margin-bottom:8px">In-app updates unavailable</div>
    <UnsupportedHint :text="inAppUpdate.explanation" />
  </div>
  <div v-else-if="inAppUpdate.available && tab === 'updates'">
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

.update-card,
.pairing-card {
  background: var(--bg-raised, var(--bg));
  border: 1px solid var(--border);
  border-radius: var(--radius, 8px);
  padding: 16px;
}
.pairing-code {
  font-family: var(--font-mono, ui-monospace, monospace);
  font-size: 28px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-align: center;
}
.pairing-steps {
  margin: 0 0 14px;
  padding-left: 22px;
  color: var(--text-secondary);
  font-size: 13px;
  line-height: 1.5;
  text-align: left;
}
.pairing-steps li + li {
  margin-top: 6px;
}
.pairing-host {
  text-align: left;
  margin-bottom: 14px;
}
.pairing-host label {
  display: block;
  font-size: 12px;
  font-weight: 600;
  margin-bottom: 6px;
}
.pairing-custom {
  display: flex;
  gap: 8px;
  align-items: center;
  margin-top: 8px;
}
.pairing-custom .pairing-input {
  flex: 1;
  resize: none;
}
.pairing-meta,
.pairing-hint {
  color: var(--text-secondary);
  font-size: 13px;
  text-align: center;
  margin: 8px 0 0;
}
.pairing-uri {
  margin: 12px 0 0;
  padding: 10px 12px;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius-xs, 6px);
  font-family: var(--font-mono, ui-monospace, monospace);
  font-size: 12px;
  white-space: pre-wrap;
  word-break: break-all;
}
.rejoin-card,
.login-offer-card {
  margin-top: 16px;
}
.login-offer-title {
  margin: 0 0 4px;
  font-size: 14px;
}
.login-offer-qr {
  width: 192px;
  height: 192px;
  margin: 12px auto 0;
}
.login-offer-qr :deep(svg) {
  width: 100%;
  height: 100%;
  display: block;
  background: #fff;
}
.pairing-input {
  width: 100%;
  padding: 8px 10px;
  background: var(--bg-input, var(--bg));
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: var(--radius-sm, 6px);
  font-size: 13px;
  font-family: var(--font-mono, ui-monospace, monospace);
  resize: vertical;
  line-height: 1.4;
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
