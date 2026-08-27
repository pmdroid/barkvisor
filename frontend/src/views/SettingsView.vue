<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref, onMounted, onUnmounted, computed, watch } from 'vue'
import { useRoute } from 'vue-router'
import api from '../api/client'
import type {
  APIKeyResponse,
  AuditEntry,
  DiskSettings,
  LibrarySettings,
  PasskeyCredential,
  RemoteAccessStatus,
  SSHKey,
} from '../api/types'
import { useToastStore } from '../stores/toast'
import { useAuthStore } from '../stores/auth'
import { useSSHKeyStore } from '../stores/sshKeys'
import { usePasskeyStore } from '../stores/passkeys'
import { isPasskeyAvailable, passkeyUnavailableMessage } from '../utils/webauthn'
import {
  advertisedHostForOffer,
  CUSTOM_ADVERTISED_HOST,
  getPairingCode,
  issuePairingCode,
  issuedAdvertisedHost,
  joinHome,
  isPairingPayload,
  revokePairingCode,
  syncAdvertiseHostPicker,
  type PairingIssue,
} from '../api/pairing'
import {
  getLoginOffer,
  issueLoginOffer,
  revokeLoginOffer,
  type LoginOffer,
} from '../api/loginOffer'
import { loginOfferSvg } from '../utils/qrSvg'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import {
  canCallDeviceAPI,
  deviceDiskSettingsPath,
  isSelfDevice,
} from '../utils/homeDeviceApi'
import { isReachabilityOk, reachabilityLabel } from '../utils/homeDeviceHealth'
import { bumpLibrarySettingsEpoch, librarySpaceCopy } from '../utils/librarySpace'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'
import {
  isCurrentPairingSeq,
  nextPairingLoadSeq,
  pairingExpiryLabel,
} from '../utils/pairingOffer'
import {
  DEFAULT_SETTINGS_TAB,
  isPairingTab,
  settingsTabFromQuery,
  shouldRunPairingTick,
  type SettingsTab,
} from '../utils/settingsTabs'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import FolderPicker from '../components/FolderPicker.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'

const route = useRoute()
const toast = useToastStore()
const auth = useAuthStore()
const sshKeyStore = useSSHKeyStore()
const passkeyStore = usePasskeyStore()
const passkeysAvailable = isPasskeyAvailable()
const passkeyUnavailable = passkeyUnavailableMessage()
const tab = ref<SettingsTab>(settingsTabFromQuery(route.query) ?? DEFAULT_SETTINGS_TAB)

const homeDeviceName = computed(() =>
  devicesStore.selfDevice ? deviceDisplayLabel(devicesStore.selfDevice) : `This ${DEVICE_LABEL}`,
)
const homeToolbarSub = computed(() =>
  devicesStore.selfDevice ? `${homeDeviceName.value} · This ${DEVICE_LABEL}` : '',
)
const advertisedHostChips = computed(() => remoteAccess.value?.advertisedHosts ?? [])
const roleTag = computed(() => (auth.isAdmin ? 'admin' : 'member'))
const roleNote = computed(() =>
  auth.isAdmin ? 'Full control on this Home' : 'Standard access on this Home',
)

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

watch([tab, pairingOffer, loginOffer], ([currentTab, pairing, login]) => {
  if (shouldRunPairingTick(currentTab, Boolean(pairing || login))) startPairingTick()
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
  fetchRemoteAccess()
  devicesStore.fetchHealth()
}

function openPairingTab() {
  tab.value = 'pairing'
  loadPairingCode()
  loadLoginOffer()
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

function openLibraryTab() {
  tab.value = 'library'
  fetchLibrarySettings()
  devicesStore.fetchHealth()
}

function openDisksTab() {
  tab.value = 'disks'
  void loadDiskSettingsTab()
}

const devicesStore = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const librarySettings = ref<LibrarySettings>({
  imageDirectory: '',
  isDefault: true,
  libraryDepotHostId: null,
  totalBytes: null,
  freeBytes: null,
  usedBytes: null,
})
const libraryDraft = ref('')
const libraryLoading = ref(false)
const librarySaving = ref(false)
const showLibraryPicker = ref(false)
const depotDraft = ref('')
const depotSaving = ref(false)

const diskSettings = ref<DiskSettings | null>(null)
const diskDirectoryDraft = ref('')
const diskDirLoading = ref(false)
const diskDirSaving = ref(false)
const showDiskDirPicker = ref(false)
const diskHostId = ref('')

const remoteAccess = ref<RemoteAccessStatus | null>(null)
const remoteAccessLoading = ref(false)
const remoteAccessSaving = ref(false)
const advertiseSelected = ref('')
const advertiseCustom = ref('')
const requireTailnetDraft = ref(false)

const advertiseHostOptions = computed(() => {
  const hosts = remoteAccess.value?.advertisedHosts ?? pairingOffer.value?.advertisedHosts ?? []
  return [
    ...hosts.map((host) => ({ value: host, label: host })),
    { value: CUSTOM_ADVERTISED_HOST, label: 'Other / DNS name…' },
  ]
})

function applyRemoteAccess(data: RemoteAccessStatus) {
  remoteAccess.value = data
  requireTailnetDraft.value = data.requireTailnetForRemote
  const picker = syncAdvertiseHostPicker(data.advertiseUrl, data.advertisedHosts ?? [])
  advertiseSelected.value = picker.selectedHost
  advertiseCustom.value = picker.customHost
}

async function fetchRemoteAccess() {
  remoteAccessLoading.value = true
  try {
    const { data } = await api.get<RemoteAccessStatus>('/system/remote-access')
    applyRemoteAccess(data)
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not load remote access'))
  } finally {
    remoteAccessLoading.value = false
  }
}

async function saveRemoteAccess() {
  if (!remoteAccess.value) return
  const advertiseUrl = advertisedHostForOffer(advertiseSelected.value, advertiseCustom.value) ?? ''
  remoteAccessSaving.value = true
  try {
    const { data } = await api.put<RemoteAccessStatus>('/home/settings/remote-access', {
      requireTailnetForRemote: requireTailnetDraft.value,
      advertiseUrl,
    })
    applyRemoteAccess(data)
    toast.success('Remote access saved')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not save remote access'))
  } finally {
    remoteAccessSaving.value = false
  }
}

const librarySpaceLine = computed(() =>
  librarySpaceCopy(librarySettings.value.totalBytes, librarySettings.value.freeBytes),
)

/** Depot is another Device — show its id without inventing that Device's capacity. */
const libraryDepotNote = computed(() => {
  const id = librarySettings.value.libraryDepotHostId?.trim()
  if (!id) return null
  const device = devicesStore.devices.find((d) => d.hostId === id)
  if (device && isSelfDevice(device)) return null
  const label = device ? deviceDisplayLabel(device) : id
  return `Library depot is ${label}. That ${DEVICE_LABEL}’s volume is not shown here.`
})

const depotOptions = computed(() => {
  const none = { value: '', label: 'None — download from the internet' }
  const devices = devicesStore.devices.map((device) => {
    const name = deviceDisplayLabel(device)
    const self = device.role === 'self' ? ` (this ${DEVICE_LABEL})` : ''
    const reach = isReachabilityOk(device.reachability)
      ? ''
      : ` — ${reachabilityLabel(device.reachability).toLowerCase()}`
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
    bumpLibrarySettingsEpoch()
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
    bumpLibrarySettingsEpoch()
    toast.success('Library path reset to the default')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    librarySaving.value = false
  }
}

function defaultDiskHostId() {
  if (!deviceScope.isAll) return deviceScope.selectedHostId
  return devicesStore.selfDevice?.hostId || devicesStore.devices[0]?.hostId || ''
}

const diskSettingsDevice = computed(() => {
  if (diskHostId.value) return devicesStore.deviceByHostId(diskHostId.value)
  return devicesStore.selfDevice
})

const diskDeviceOptions = computed(() =>
  devicesStore.devices.map((device) => {
    const name = isSelfDevice(device)
      ? `This ${DEVICE_LABEL}`
      : deviceDisplayLabel(device)
    const reach = canCallDeviceAPI(device)
      ? ''
      : ` — ${reachabilityLabel(device.reachability).toLowerCase()}`
    return { value: device.hostId, label: `${name}${reach}`, disabled: !canCallDeviceAPI(device) }
  }),
)

const diskDirCanEdit = computed(() => {
  const device = diskSettingsDevice.value
  return !device || canCallDeviceAPI(device)
})

function diskSettingsApiPath() {
  const device = diskSettingsDevice.value
  return device ? deviceDiskSettingsPath(device) : '/system/disk/settings'
}

async function loadDiskSettingsTab() {
  await devicesStore.fetchHealth()
  const next = diskHostId.value || defaultDiskHostId()
  if (diskHostId.value !== next) {
    diskHostId.value = next
    return
  }
  await fetchDiskSettings()
}

async function fetchDiskSettings() {
  diskDirLoading.value = true
  try {
    const { data } = await api.get<DiskSettings>(diskSettingsApiPath())
    diskSettings.value = data
    diskDirectoryDraft.value = data.diskDirectory
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not load disk directory'))
  } finally {
    diskDirLoading.value = false
  }
}

watch(diskHostId, () => {
  if (tab.value !== 'disks') return
  showDiskDirPicker.value = false
  void fetchDiskSettings()
})

async function saveDiskSettings() {
  if (!diskDirCanEdit.value) return
  diskDirSaving.value = true
  try {
    const { data } = await api.put<DiskSettings>(diskSettingsApiPath(), {
      diskDirectory: diskDirectoryDraft.value,
    })
    diskSettings.value = data
    diskDirectoryDraft.value = data.diskDirectory
    toast.success('Disk directory saved')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not save disk directory'))
  } finally {
    diskDirSaving.value = false
  }
}

async function resetDiskSettings() {
  diskDirectoryDraft.value = ''
  await saveDiskSettings()
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
const newKeyKind = ref('full')
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
      kind: newKeyKind.value,
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

// SSH Keys
const showAddSSHKey = ref(false)
const newSSHKeyName = ref('')
const newSSHKeyPublicKey = ref('')
const addSSHKeyLoading = ref(false)
const deleteSSHKeyTarget = ref<SSHKey | null>(null)
const deletingSSHKey = ref(false)
const addPasskeyLoading = ref(false)
const newPasskeyName = ref('')
const deletePasskeyTarget = ref<PasskeyCredential | null>(null)
const deletingPasskey = ref(false)

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

async function addPasskey() {
  addPasskeyLoading.value = true
  try {
    await passkeyStore.add(newPasskeyName.value.trim() || undefined)
    toast.success('Passkey added')
    newPasskeyName.value = ''
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    addPasskeyLoading.value = false
  }
}

async function doDeletePasskey() {
  if (!deletePasskeyTarget.value) return
  deletingPasskey.value = true
  try {
    await passkeyStore.remove(deletePasskeyTarget.value.id)
    toast.success('Passkey deleted')
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    deletingPasskey.value = false
    deletePasskeyTarget.value = null
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

function applySettingsTab(next: SettingsTab) {
  if (isPairingTab(next)) {
    openPairingTab()
    return
  }
  if (next === 'home') {
    openHomeTab()
    return
  }
  if (next === 'library') {
    openLibraryTab()
    return
  }
  if (next === 'disks') {
    openDisksTab()
    return
  }
  if (next === 'sshkeys') {
    tab.value = 'sshkeys'
    sshKeyStore.fetchAll()
    return
  }
  if (next === 'passkeys') {
    tab.value = 'passkeys'
    passkeyStore.fetchAll()
    return
  }
  if (next === 'audit') {
    tab.value = 'audit'
    fetchAudit()
    return
  }
  tab.value = next
}

onMounted(() => {
  fetchKeys()
  const requested = settingsTabFromQuery(route.query)
  if (requested) applySettingsTab(requested)
})

onUnmounted(() => {
  stopPairingTick()
})
</script>

<template>
  <div class="ops-page">
  <div class="ops-toolbar">
    <h1>Settings</h1>
    <span v-if="homeToolbarSub" class="ops-sub">{{ homeToolbarSub }}</span>
    <div class="ops-actions">
      <AppButton
        v-if="tab === 'home'"
        variant="primary"
        :loading="remoteAccessSaving || depotSaving"
        :disabled="!remoteAccess || remoteAccessLoading"
        @click="saveRemoteAccess(); saveDepotSettings()"
      >Save changes</AppButton>
    </div>
  </div>
  <div class="ops-body">

  <div class="tabs">
    <button :class="{ active: tab === 'home' }" @click="openHomeTab">{{ HOME_LABEL }}</button>
    <button :class="{ active: isPairingTab(tab) }" @click="openPairingTab">Pairing</button>
    <button :class="{ active: tab === 'library' }" @click="openLibraryTab">Library</button>
    <button :class="{ active: tab === 'disks' }" @click="openDisksTab">Disks</button>
    <button :class="{ active: tab === 'apikeys' }" @click="tab = 'apikeys'">API Keys</button>
    <button :class="{ active: tab === 'sshkeys' }" @click="tab = 'sshkeys'; sshKeyStore.fetchAll()">SSH Keys</button>
    <button :class="{ active: tab === 'passkeys' }" @click="tab = 'passkeys'; passkeyStore.fetchAll()">Passkeys</button>
    <button :class="{ active: tab === 'audit' }" @click="tab = 'audit'; fetchAudit()">Audit Log</button>
  </div>

  <!-- Home — remote access, advertise URL, Library depot. Pairing QR lives on the Pairing tab. -->
  <div v-if="tab === 'home'">
    <div class="facts">
      <div class="fact">
        <span class="k">Device name<span>How this Device appears in the Home</span></span>
        <span class="v">{{ homeDeviceName }}</span>
      </div>
      <div class="fact">
        <span class="k">Advertised hosts<span>Addresses other Devices use to reach this one</span></span>
        <span class="v">
          <span v-if="advertisedHostChips.length" class="hosts">
            <span v-for="host in advertisedHostChips" :key="host" class="host">{{ host }}</span>
          </span>
          <span v-else style="color:var(--text-dim)">—</span>
        </span>
      </div>
      <div class="fact">
        <span class="k">Role<span>What you can do on this Home</span></span>
        <span class="v role">
          <span class="role-tag">{{ roleTag }}</span>
          <span style="font-size:12px;color:var(--text-dim)">{{ roleNote }}</span>
        </span>
      </div>
      <div class="fact" style="border-bottom:0">
        <span class="k">Add a {{ DEVICE_LABEL }}<span>Grow this Home</span></span>
        <span class="v pair-line">
          Pairing is how you add a {{ DEVICE_LABEL }}. <a @click="openPairingTab">Open Pairing →</a>
        </span>
      </div>
    </div>
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
        BarkVisor does not configure WireGuard. If you run your own tunnel, pick that address
        as the advertise URL.
      </p>
      <div class="form-group" style="margin:0 0 12px;text-align:left">
        <label for="advertise-url">Advertise URL</label>
        <AppSelect
          id="advertise-url"
          :modelValue="advertiseSelected"
          :options="advertiseHostOptions"
          :disabled="!remoteAccess || remoteAccessLoading || remoteAccessSaving"
          @update:modelValue="advertiseSelected = $event"
        />
        <div v-if="advertiseSelected === CUSTOM_ADVERTISED_HOST" class="pairing-custom">
          <input
            v-model="advertiseCustom"
            class="pairing-input"
            type="text"
            placeholder="hostname, MagicDNS, or tailnet IP"
            autocomplete="off"
            spellcheck="false"
            :disabled="!remoteAccess || remoteAccessLoading || remoteAccessSaving"
            @keydown.enter.prevent="saveRemoteAccess"
          />
        </div>
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
  </div>

  <!-- Pairing / Add a Device (PAS-51) — existing /api/pairing/codes, not a second wizard -->
  <div v-if="isPairingTab(tab)">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
      <p style="color:var(--text-secondary);font-size:13px;margin:0">
        Add a {{ DEVICE_LABEL }} to this {{ HOME_LABEL }}. On the new {{ DEVICE_LABEL }}, run
        <code>barkvisor join --code</code> with this pairing offer.
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
        <li>Copy the full <code>barkvisor://</code> offer, not only the short code.</li>
        <li>
          On the new {{ DEVICE_LABEL }}, run
          <code>barkvisor join --code '&lt;offer&gt;'</code>.
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

    <DataTable v-else :columns="[{ key: 'name', label: 'Name' }, { key: 'kind', label: 'Kind' }, { key: 'key', label: 'Key' }, { key: 'expires', label: 'Expires' }, { key: 'lastUsed', label: 'Last Used' }, { key: 'created', label: 'Created' }, { key: 'actions', label: '', align: 'right' }]">
          <tr v-for="k in apiKeys" :key="k.id">
            <td style="font-weight:500">{{ k.name }}</td>
            <td><span class="badge badge-gray">{{ k.kind === 'inference' ? 'inference' : 'full' }}</span></td>
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

  <div v-if="tab === 'passkeys'">
    <div v-if="!passkeysAvailable" style="color:var(--text-secondary);font-size:13px;margin-bottom:16px">
      {{ passkeyUnavailable }}
    </div>
    <template v-else>
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px;gap:12px">
        <p style="color:var(--text-secondary);font-size:13px;margin:0">
          Passkeys sign you in to this Home without a password. They stay on this user.
        </p>
        <div style="display:flex;gap:8px;align-items:center">
          <input v-model="newPasskeyName" placeholder="Name (optional)" style="width:160px" />
          <AppButton variant="primary" icon="plus" :loading="addPasskeyLoading" loadingText="Waiting..." @click="addPasskey">Add passkey</AppButton>
        </div>
      </div>
      <EmptyState v-if="passkeyStore.keys.length === 0" icon="key" title="No passkeys yet. Add one to sign in without a password." />
      <DataTable v-else :columns="[{ key: 'name', label: 'Name' }, { key: 'lastUsed', label: 'Last used' }, { key: 'created', label: 'Created' }, { key: 'actions', label: '', align: 'right' }]">
        <tr v-for="k in passkeyStore.keys" :key="k.id">
          <td style="font-weight:500">{{ k.name }}</td>
          <td style="color:var(--text-secondary)">{{ k.lastUsedAt ? formatDate(k.lastUsedAt) : 'Never' }}</td>
          <td style="color:var(--text-secondary)">{{ formatDate(k.createdAt) }}</td>
          <td style="text-align:right">
            <AppButton size="sm" style="color:var(--red)" @click="deletePasskeyTarget = k">Delete</AppButton>
          </td>
        </tr>
      </DataTable>
    </template>
  </div>

  <ConfirmDialog
    v-if="deletePasskeyTarget"
    title="Delete passkey"
    :message="`Delete passkey &quot;${deletePasskeyTarget.name}&quot;? You will not be able to sign in with it.`"
    confirm-label="Delete"
    :danger="true"
    :loading="deletingPasskey"
    @confirm="doDeletePasskey"
    @cancel="deletePasskeyTarget = null"
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
        <optgroup label="Passkey">
          <option value="auth.passkey.register">auth.passkey.register</option>
          <option value="auth.passkey.login">auth.passkey.login</option>
          <option value="auth.passkey.delete">auth.passkey.delete</option>
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
      <p
        v-if="librarySpaceLine"
        style="color:var(--text-secondary);font-size:13px;margin:8px 0 0 0"
      >
        {{ librarySpaceLine }}
      </p>
      <p
        v-else-if="!libraryLoading"
        style="color:var(--text-dim);font-size:13px;margin:8px 0 0 0"
      >
        Capacity unavailable
      </p>
      <p
        v-if="libraryDepotNote"
        style="color:var(--text-tertiary);font-size:12px;margin:8px 0 0 0"
      >
        {{ libraryDepotNote }}
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
    <div style="margin-top:28px;max-width:640px">
      <p style="color:var(--text-secondary);font-size:13px;margin:0 0 10px 0">
        Catalog Download writes into this {{ DEVICE_LABEL }}’s Library. Other
        {{ DEVICE_LABEL }}s fetch from it first. If that {{ DEVICE_LABEL }} is
        down or the checksum does not match, they download from the internet.
        Starting a Workload on this {{ DEVICE_LABEL }} never waits on the Library depot.
        If this is unset, a {{ DEVICE_LABEL }} with exactly one peer uses that peer as the depot.
      </p>
      <div class="form-group">
        <label>Library depot</label>
        <AppSelect
          :modelValue="depotDraft"
          :options="depotOptions"
          :disabled="libraryLoading || depotSaving"
          @update:modelValue="depotDraft = $event"
        />
      </div>
      <div style="display:flex;gap:8px;margin-top:16px">
        <AppButton
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
    <FolderPicker
      v-if="showLibraryPicker"
      :model-value="libraryDraft"
      @update:model-value="libraryDraft = $event"
      @close="showLibraryPicker = false"
    />
  </div>

  <div v-if="tab === 'disks'">
    <p style="color:var(--text-secondary);font-size:13px;margin:0 0 16px 0">
      New disks go here on the selected {{ DEVICE_LABEL }}.
    </p>
    <div v-if="diskDeviceOptions.length" class="form-group" style="max-width:640px">
      <label>{{ DEVICE_LABEL }}</label>
      <AppSelect
        :modelValue="diskHostId"
        :options="diskDeviceOptions"
        :disabled="diskDirLoading || diskDirSaving"
        @update:modelValue="diskHostId = $event"
      />
    </div>
    <div class="form-group" style="max-width:640px">
      <label>Default VM disk directory</label>
      <div style="display:flex;gap:8px;align-items:center">
        <input
          v-model="diskDirectoryDraft"
          :disabled="diskDirLoading || diskDirSaving || !diskDirCanEdit"
          placeholder="/var/lib/barkvisor/disks"
          style="flex:1"
        />
        <AppButton
          size="sm"
          :disabled="diskDirLoading || diskDirSaving || !diskDirCanEdit"
          @click="showDiskDirPicker = true"
        >
          Browse
        </AppButton>
      </div>
      <p style="color:var(--text-tertiary);font-size:12px;margin:8px 0 0 0">
        {{ diskSettings?.isDefault ? 'Using the default path on this Device.' : 'Using a custom disk directory.' }}
        Absolute path required. Must be writable by the daemon and must not contain a comma.
      </p>
    </div>
    <div style="display:flex;gap:8px;margin-top:16px">
      <AppButton
        variant="primary"
        :loading="diskDirSaving"
        loading-text="Saving..."
        :disabled="diskDirLoading || !diskDirCanEdit"
        @click="saveDiskSettings"
      >
        Save
      </AppButton>
      <AppButton
        :disabled="diskDirLoading || diskDirSaving || !diskDirCanEdit || diskSettings?.isDefault"
        @click="resetDiskSettings"
      >
        Reset to default
      </AppButton>
    </div>
    <FolderPicker
      v-if="showDiskDirPicker"
      :model-value="diskDirectoryDraft"
      :device="diskSettingsDevice"
      @update:model-value="diskDirectoryDraft = $event"
      @close="showDiskDirPicker = false"
    />
  </div>

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
        <div class="form-group">
          <label>Kind</label>
          <AppSelect v-model="newKeyKind">
            <option value="full">Full (this Home API)</option>
            <option value="inference">Inference (Ollama list + chat completions)</option>
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
  </div>
  </div>
</template>

<style scoped>
.tabs {
  display: flex;
  gap: 2px;
  margin-bottom: 16px;
  border-bottom: 1px solid var(--border-glass);
}
.tabs button {
  padding: 8px 14px;
  background: transparent;
  border: none;
  border-bottom: 2px solid transparent;
  border-radius: 0;
  margin-bottom: -1px;
  color: var(--text-dim);
  cursor: pointer;
  font-size: 13px;
  font-weight: 600;
}
.tabs button.active {
  background: transparent;
  color: var(--text);
  border-bottom-color: var(--accent);
}
.tabs button:hover:not(.active) {
  color: var(--text-secondary);
}
.badge-yellow { background: var(--yellow-muted, rgba(234,179,8,0.15)); color: var(--yellow, #eab308); }

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
</style>
