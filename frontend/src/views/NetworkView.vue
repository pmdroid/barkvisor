<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import api from '../api/client'
import type { BridgeActionResponse, BridgeInfo, HomeDeviceHealthSnapshot, HostBridgeReadiness, HostInterface, NextBridgeResponse } from '../api/types'
import HostInterfaceAddressList from '../components/HostInterfaceAddressList.vue'
import GuestCommandAccordion from '../components/ui/GuestCommandAccordion.vue'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import FormError from '../components/ui/FormError.vue'
import AppModal from '../components/ui/AppModal.vue'
import UnsupportedHint from '../components/ui/UnsupportedHint.vue'
import { useToastStore } from '../stores/toast'
import { useCapabilitiesStore } from '../stores/capabilities'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useDeviceNetworksStore, type HomeNetworkRow, type NetworkWriteBody } from '../stores/deviceNetworks'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useNetworkStore } from '../stores/networks'
import { storeToRefs } from 'pinia'
import { bridgeManagementMode, useFeature } from '../composables/useFeature'
import { defaultCapabilities } from '../utils/capabilitiesParse'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import {
  canCallDeviceAPI,
  deviceBridgesNextPath,
  deviceBridgesPath,
  deviceHostBridgeReadinessPath,
  isSelfDevice,
} from '../utils/homeDeviceApi'
import {
  defaultUnusedPort,
  linuxRefusesWifiPort,
  nextFreeBridgeName,
  takenBridgeNames,
  unusedBridgePorts,
} from '../utils/createHostBridge'
import {
  hostBridgeCanApply,
  hostBridgeSetupPending,
  linuxBridgeSetupGroups,
  linuxBridgeStatusSummary,
  macosSocketVmnetSetupGroups,
  macosSocketVmnetStatusSummary,
} from '../utils/linuxBridgeSetup'
import {
  addressesFromInterface,
  buildHostBridgeApplyBody,
  type EditableHostAddress,
  validateAddressList,
} from '../utils/hostInterfaceAddresses'
import {
  bridgedPickerInterfaces,
  bridgeSetupInterfaceKey,
  bridgeMemberNames,
  effectiveInterfaceForDisplay,
  formatInterfaceAddressSummary,
  formatInterfaceLinkSummary,
  inferInterfaceRole,
  interfaceAddressFieldsReadOnly,
  interfaceBridgeRoleDetail,
  interfaceOwnsAddressApply,
  interfaceOwnsBridgeSetupApply,
  interfaceRoleBadgeClass,
  interfaceRoleLabel,
  interfaceRouteColumn,
  interfaceBridgeColumn,
  interfaceEnslavedToBridge,
  resolveBridgeApplyNic,
  pendingCommitMatchesInterface,
  hostBridgeActionPath,
  interfaceAssociatedBridge,
  interfaceShowsDelete,
} from '../utils/hostInterfaceDisplay'
import { DEVICE_LABEL, HOME_LABEL } from '../utils/terminology'
import { healthLabel, vmHealth } from '../utils/workloadHealth'
import { scopeRows } from '../utils/deviceScope'

const toast = useToastStore()
const caps = useCapabilitiesStore()
const devicesStore = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const homeNets = useDeviceNetworksStore()
const homeWorkloads = useDeviceWorkloadsStore()
const networkStore = useNetworkStore()
const bridged = useFeature('bridgedNetworking')
const { networks } = storeToRefs(networkStore)

const localInterfaces = ref<HostInterface[]>([])
const localBridges = ref<BridgeInfo[]>([])

const showCreate = ref(false)
const editingId = ref<string | null>(null)
const formHostId = ref('')
const newName = ref('')
const newMode = ref<'nat' | 'bridged' | 'isolated'>('nat')
const newBridge = ref('')
const newDns = ref('')
const loading = ref(false)
const error = ref('')

const activeTab = ref<'interfaces' | 'vm'>('interfaces')
const selectedInterfaceKey = ref('')
const interfaceEditRows = ref<EditableHostAddress[]>([])
const interfaceGateway = ref('')
const interfaceDNS = ref('')

const deleteTarget = ref<{ id: string; name: string; hostId: string } | null>(null)
const deleting = ref(false)

const useHomeUnion = computed(() => devicesStore.devices.length > 0)

const homeRows = computed<HomeNetworkRow[]>(() => {
  const rows = useHomeUnion.value
    ? homeNets.homeRows(devicesStore.devices)
    : networks.value.map((network) => ({
        network,
        hostId: devicesStore.selfDevice?.hostId || '',
        label: '',
        role: 'self',
        reachable: true,
      }))
  return scopeRows(rows, deviceScope.selectedHostId)
})

const pageLoading = computed(() => {
  if (devicesStore.loading || networkStore.loading) return true
  return devicesStore.devices.some((device) => homeNets.isLoading(device.hostId))
})

const loadErrors = computed(() =>
  devicesStore.devices
    .map((device) => homeNets.errorFor(device.hostId))
    .filter((message): message is string => Boolean(message)),
)

const formDevice = computed(() => {
  if (formHostId.value) return devicesStore.deviceByHostId(formHostId.value)
  return devicesStore.selfDevice
})

/** Per-device caps, falling back to already-loaded self inventory (not fail-closed defaults). */
function deviceCapsFor(hostId: string) {
  const loaded = hostId ? homeNets.capsFor(hostId) : null
  if (loaded) return loaded
  const device = hostId
    ? devicesStore.deviceByHostId(hostId)
    : devicesStore.selfDevice
  if (device && isSelfDevice(device)) return caps.currentHost
  return defaultCapabilities
}

const formCaps = computed(() => {
  if (useHomeUnion.value && formHostId.value) {
    return deviceCapsFor(formHostId.value)
  }
  return caps.currentHost
})

const formNetworkModes = computed(() => formCaps.value.networkModes ?? defaultCapabilities.networkModes!)
const formBridgedAvailable = computed(() => formCaps.value.supportsBridgedNetworking)
const formBridgedExplanation = computed(() => {
  const row = formCaps.value.details?.find((detail) => detail.code === 'bridgedNetworking')
  if (row && !row.supported) return row.remediation || 'Bridged networking is not available on this Device.'
  return bridged.explanation || 'Bridged networking is not available on this Device.'
})

const formDeviceOptions = computed(() =>
  scopeRows(devicesStore.devices, deviceScope.selectedHostId).map((device) => ({
    value: device.hostId,
    label: deviceDisplayLabel(device),
    disabled: !canCallDeviceAPI(device) || Boolean(editingId.value),
  })),
)

type InterfaceTableRow = {
  key: string
  hostId: string
  deviceLabel: string
  iface: HostInterface
}

const interfaceHostId = computed(() => {
  if (selectedInterfaceRow.value) return selectedInterfaceRow.value.hostId
  if (!deviceScope.isAll) return deviceScope.selectedHostId
  return devicesStore.selfDevice?.hostId
    || devicesStore.devices.find((device) => canCallDeviceAPI(device))?.hostId
    || ''
})

const interfaceTableRows = computed<InterfaceTableRow[]>(() => {
  const rows: InterfaceTableRow[] = []
  const devices = useHomeUnion.value
    ? scopeRows(devicesStore.devices, deviceScope.selectedHostId)
    : devicesStore.selfDevice
      ? [devicesStore.selfDevice]
      : []
  for (const device of devices) {
    if (!canCallDeviceAPI(device)) continue
    const ifaces = useHomeUnion.value
      ? homeNets.interfacesFor(device.hostId)
      : localInterfaces.value
    for (const iface of ifaces) {
      if (iface.name === 'lo' || iface.name === 'lo0') continue
      rows.push({
        key: `${device.hostId}:${iface.name}`,
        hostId: device.hostId,
        deviceLabel: deviceDisplayLabel(device),
        iface,
      })
    }
  }
  return rows
})

const selectedInterfaceRow = computed(() =>
  interfaceTableRows.value.find((row) => row.key === selectedInterfaceKey.value) ?? null,
)

const showInterfaceDeviceColumn = computed(() =>
  useHomeUnion.value && deviceScope.isAll,
)

const hostInterfaces = computed(() => {
  if (useHomeUnion.value && interfaceHostId.value) return homeNets.interfacesFor(interfaceHostId.value)
  return localInterfaces.value
})

/** Host interfaces for the Create/Edit Workload network modal (uses form device, not drawer selection). */
const formHostInterfaces = computed(() => {
  if (useHomeUnion.value && formHostId.value) return homeNets.interfacesFor(formHostId.value)
  return localInterfaces.value
})

const bridges = computed(() => {
  if (useHomeUnion.value && interfaceHostId.value) return homeNets.bridgesFor(interfaceHostId.value)
  return localBridges.value
})

const createBridgeDevice = computed(() => {
  if (createBridgeHostId.value) return devicesStore.deviceByHostId(createBridgeHostId.value)
  return devicesStore.selfDevice
})

const createBridgeCaps = computed(() => {
  if (useHomeUnion.value && createBridgeHostId.value) return deviceCapsFor(createBridgeHostId.value)
  return caps.currentHost
})

const createBridgeIfaces = computed(() => {
  if (useHomeUnion.value && createBridgeHostId.value) return homeNets.interfacesFor(createBridgeHostId.value)
  return localInterfaces.value
})

const createBridgeReadiness = computed(() => {
  const hostId = createBridgeHostId.value || devicesStore.selfDevice?.hostId || ''
  return hostId ? readinessByHost.value[hostId] ?? null : null
})

const createBridgePorts = computed(() =>
  unusedBridgePorts(
    createBridgeIfaces.value,
    createBridgeReadiness.value,
    createBridgeCaps.value.platform,
  ),
)

const createBridgeAddressValidation = computed(() =>
  validateAddressList(createBridgeRows.value, {
    onlyUplink: createBridgeReadiness.value?.onlyUplink,
  }),
)

function deviceBridgeGuideMode(device: HomeDeviceHealthSnapshot) {
  const c = deviceCapsFor(device.hostId)
  return bridgeManagementMode({
    platform: c.platform || device.platform?.os,
    supportsHostBridgeManagement: c.supportsHostBridgeManagement,
    supportsManagedBridgeDaemon: c.supportsManagedBridgeDaemon,
  })
}

const selectedInterfaceMode = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row) return 'hidden' as const
  const device = devicesStore.deviceByHostId(row.hostId)
  if (device) return deviceBridgeGuideMode(device)
  return 'hidden' as const
})

const selectedInterfaceReadiness = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row) return null
  return readinessByHost.value[row.hostId] ?? null
})

const interfaceAddressValidation = computed(() =>
  validateAddressList(interfaceEditRows.value, {
    onlyUplink: selectedInterfaceReadiness.value?.onlyUplink,
    gateway: interfaceGateway.value,
  }),
)

const canApplyAddresses = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row) return false
  const ready = selectedInterfaceReadiness.value
  const role = inferInterfaceRole(row.iface, ready, selectedInterfaceMode.value)
  if (!interfaceOwnsAddressApply(role, row.iface, ready, selectedInterfaceMode.value)) return false
  if (!showAddressEditor.value) return false
  const deviceCaps = deviceCapsFor(row.hostId)
  if (!hostBridgeCanApply({
    platform: deviceCaps.platform,
    supportsHostMutation: deviceCaps.supportsHostMutation,
    supportsHostBridgeManagement: deviceCaps.supportsHostBridgeManagement,
    supportsManagedBridgeDaemon: deviceCaps.supportsManagedBridgeDaemon,
  })) return false
  return interfaceAddressValidation.value.ok
})

const canApplySelectedInterface = computed(() => canApplyAddresses.value)

const showAddressEditor = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row) return false
  if (selectedInterfaceMode.value === 'linux-guide' && selectedInterfaceRole.value === 'bridge') {
    return false
  }
  return interfaceOwnsAddressApply(
    selectedInterfaceRole.value,
    row.iface,
    selectedInterfaceReadiness.value,
    selectedInterfaceMode.value,
  )
})

const showBridgeSetupPanel = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row) return false
  return interfaceOwnsBridgeSetupApply(
    selectedInterfaceRole.value,
    row.iface,
    selectedInterfaceReadiness.value,
    selectedInterfaceMode.value,
  )
})

const applyButtonLabel = computed(() => 'Apply addresses')

const selectedBridgeMembers = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row || selectedInterfaceRole.value !== 'bridge') return []
  return bridgeMemberNames(row.iface.name, selectedInterfaceReadiness.value)
})

const selectedInterfaceReadOnly = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row) return true
  return interfaceAddressFieldsReadOnly(
    selectedInterfaceRole.value,
    row.iface,
    selectedInterfaceReadiness.value,
    selectedInterfaceMode.value,
  )
})

const selectedInterfaceRole = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row) return 'external' as const
  return inferInterfaceRole(row.iface, selectedInterfaceReadiness.value, selectedInterfaceMode.value)
})

const interfaceBridgeGuideGroups = computed(() => {
  const row = selectedInterfaceRow.value
  const ready = selectedInterfaceReadiness.value
  if (!row || !ready) return []
  const role = inferInterfaceRole(row.iface, ready, selectedInterfaceMode.value)
  if (selectedInterfaceMode.value === 'linux-guide') {
    if (role === 'bridge') return linuxBridgeSetupGroups(ready)
    if (interfaceEnslavedToBridge(row.iface, ready)) return []
    if (interfaceOwnsBridgeSetupApply(role, row.iface, ready, selectedInterfaceMode.value)) {
      return linuxBridgeSetupGroups(ready)
    }
    return []
  }
  if (!interfaceOwnsBridgeSetupApply(role, row.iface, ready, selectedInterfaceMode.value)) return []
  return macosSocketVmnetSetupGroups(ready)
})

const interfaceBridgeStatusSummary = computed(() => {
  const row = selectedInterfaceRow.value
  const ready = selectedInterfaceReadiness.value
  if (!row || !ready) return ''
  if (!showBridgeSetupPanel.value) return ''
  const device = devicesStore.deviceByHostId(row.hostId)
  const name = device ? deviceDisplayLabel(device) : undefined
  return selectedInterfaceMode.value === 'macos-guide'
    ? macosSocketVmnetStatusSummary(ready, name)
    : linuxBridgeStatusSummary(ready, name)
})

const linuxReadinessLoading = ref(false)
const readinessByHost = ref<Record<string, HostBridgeReadiness>>({})

const formReadiness = computed(() => {
  const hostId = formHostId.value
  if (hostId && readinessByHost.value[hostId]) return readinessByHost.value[hostId]
  return Object.values(readinessByHost.value)[0] ?? null
})

const formBridgePickerInterfaces = computed(() =>
  bridgedPickerInterfaces(formHostInterfaces.value, formReadiness.value, newBridge.value),
)

const linuxApplyLoading = ref(false)
const linuxApplyResult = ref<BridgeActionResponse | null>(null)
const linuxApplyConfirm = ref<'apply' | 'revert' | 'delete' | null>(null)
const linuxApplySource = ref<'drawer' | 'create-bridge'>('drawer')

const createMenuOpen = ref(false)
const showCreateBridge = ref(false)
const createBridgeHostId = ref('')
const createBridgeName = ref('')
const createBridgeNic = ref('')
const createBridgeRows = ref<EditableHostAddress[]>([{ id: 'dhcp', kind: 'dhcp', cidr: '' }])
const createBridgeGateway = ref('')
const createBridgeDNS = ref('')
const createBridgeVmNetwork = ref(true)
const createBridgeError = ref('')

type PendingCommitState = {
  hostId: string
  nic: string
  target: string
  commitDeadline: string
  rollbackSeconds: number
}

const pendingCommit = ref<PendingCommitState | null>(null)
const pendingCommitSecondsLeft = ref(0)
let pendingCommitTimer: ReturnType<typeof setInterval> | null = null
let pendingCommitAutoRevert = false

function stopPendingCommitTimer() {
  if (pendingCommitTimer) {
    clearInterval(pendingCommitTimer)
    pendingCommitTimer = null
  }
}

function updatePendingCommitCountdown() {
  if (!pendingCommit.value) {
    pendingCommitSecondsLeft.value = 0
    return
  }
  const deadline = Date.parse(pendingCommit.value.commitDeadline)
  const left = Math.ceil((deadline - Date.now()) / 1000)
  pendingCommitSecondsLeft.value = Math.max(0, left)
  if (left <= 0 && !pendingCommitAutoRevert) {
    pendingCommitAutoRevert = true
    void autoRevertPendingCommit()
  }
}

function startPendingCommitTimer() {
  stopPendingCommitTimer()
  updatePendingCommitCountdown()
  pendingCommitTimer = setInterval(updatePendingCommitCountdown, 1000)
}

function clearPendingCommitState() {
  stopPendingCommitTimer()
  pendingCommit.value = null
  pendingCommitSecondsLeft.value = 0
  pendingCommitAutoRevert = false
}

function setPendingCommitFromResponse(hostId: string, nic: string, data: BridgeActionResponse) {
  if (!data.pendingCommit || !data.commitDeadline) {
    return
  }
  const ready = readinessByHost.value[hostId]
  pendingCommitAutoRevert = false
  pendingCommit.value = {
    hostId,
    nic,
    target: data.target ?? ready?.pendingCommit?.target ?? nic,
    commitDeadline: data.commitDeadline,
    rollbackSeconds: data.rollbackSeconds ?? 30,
  }
  startPendingCommitTimer()
}

function syncPendingCommitFromReadiness(hostId: string, ready: HostBridgeReadiness, nic: string) {
  const row = ready.pendingCommit
  if (!row) {
    if (pendingCommit.value?.hostId === hostId) clearPendingCommitState()
    return
  }
  if (Date.parse(row.commitDeadline) <= Date.now()) {
    if (pendingCommit.value?.hostId === hostId && !pendingCommitAutoRevert) {
      pendingCommitAutoRevert = true
      void autoRevertPendingCommit()
    }
    return
  }
  pendingCommitAutoRevert = false
  pendingCommit.value = {
    hostId,
    nic,
    target: row.target,
    commitDeadline: row.commitDeadline,
    rollbackSeconds: row.rollbackSeconds,
  }
  startPendingCommitTimer()
}

const showPendingCommitBanner = computed(() => {
  const row = selectedInterfaceRow.value
  const pending = pendingCommit.value
  if (!row || !pending || pending.hostId !== row.hostId) return false
  return pendingCommitMatchesInterface(
    pending,
    row.iface.name,
    selectedInterfaceMode.value,
  )
})

async function keepPendingCommit() {
  const pending = pendingCommit.value
  const row = selectedInterfaceRow.value
  if (!pending || !row) return
  const device = devicesStore.deviceByHostId(pending.hostId)
  linuxApplyLoading.value = true
  try {
    const path = device && useHomeUnion.value ? deviceBridgesPath(device) : '/system/bridges'
    const { data } = await api.post<BridgeActionResponse>(path, {
      action: 'commit',
      interface: pending.nic,
      bridge: pending.target,
      confirm: true,
    })
    linuxApplyResult.value = data
    if (data.success) {
      clearPendingCommitState()
      toast.success(data.message || 'Kept host network changes.')
      await fetchHostReadiness(device)
      await refreshInterfaceContext(row.hostId)
    } else if (data.message) {
      toast.error(data.message)
    }
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    linuxApplyLoading.value = false
  }
}

async function autoRevertPendingCommit() {
  const pending = pendingCommit.value
  if (!pending) return
  const row = selectedInterfaceRow.value
  const device = devicesStore.deviceByHostId(pending.hostId)
  linuxApplyLoading.value = true
  try {
    const path = hostBridgeRevertPath(pending.nic, device ?? undefined, pending.target)
    const { data } = await api.delete<BridgeActionResponse>(path, {
      data: { confirm: true, action: 'revert', interface: pending.nic, bridge: pending.target },
    })
    clearPendingCommitState()
    if (data.success) {
      toast.info(data.message || 'Host network changes auto-reverted.')
      if (row) {
        await fetchHostReadiness(device)
        await refreshInterfaceContext(row.hostId)
      }
    }
  } catch {
    toast.error('Auto-revert failed. Use Revert manually if connectivity is broken.')
  } finally {
    linuxApplyLoading.value = false
    pendingCommitAutoRevert = false
  }
}

function hostBridgeRevertPath(
  nic: string,
  device?: HomeDeviceHealthSnapshot | null,
  target?: string | null,
) {
  const base = device && useHomeUnion.value ? deviceBridgesPath(device) : '/system/bridges'
  const mode = device ? deviceBridgeGuideMode(device) : 'hidden'
  return hostBridgeActionPath(base, nic, mode, target)
}

function rowKey(row: HomeNetworkRow): string {
  return `${row.hostId}:${row.network.id}`
}

type PendingBridge = { key: string; hostId: string; label: string; role: string }

const pendingBridges = computed<PendingBridge[]>(() => {
  const devices = scopeRows(devicesStore.devices, deviceScope.selectedHostId)
  const items: PendingBridge[] = []
  for (const device of devices) {
    const capsFor = deviceCapsFor(device.hostId)
    const hasBridge = homeNets.networksFor(device.hostId).some((net) => net.mode === 'bridged')
    if (!hostBridgeSetupPending({
      supportsBridgedNetworking: capsFor.supportsBridgedNetworking,
      hasBridgedNetwork: hasBridge,
      hostReady: readinessByHost.value[device.hostId]?.ready,
    })) continue
    items.push({
      key: `pending:${device.hostId}`,
      hostId: device.hostId,
      label: deviceDisplayLabel(device),
      role: isSelfDevice(device) ? 'self' : 'member',
    })
  }
  return items
})

const selectedKey = ref('')
const selectedRow = computed(() =>
  homeRows.value.find((row) => rowKey(row) === selectedKey.value) ?? null,
)

watch(homeRows, (rows) => {
  if (!rows.length) {
    selectedKey.value = ''
    return
  }
  const keys = rows.map((row) => rowKey(row))
  if (!keys.includes(selectedKey.value)) {
    selectedKey.value = keys[0] ?? ''
  }
}, { immediate: true })

watch(interfaceTableRows, (rows) => {
  if (!rows.length) {
    selectedInterfaceKey.value = ''
    return
  }
  if (!rows.some((row) => row.key === selectedInterfaceKey.value)) {
    selectedInterfaceKey.value = rows[0]?.key ?? ''
  }
}, { immediate: true })

watch(selectedInterfaceRow, (row) => {
  if (!row) {
    interfaceEditRows.value = []
    interfaceGateway.value = ''
    interfaceDNS.value = ''
    return
  }
  interfaceEditRows.value = addressesFromInterface(displayInterfaceForRow(row))
  const displayIface = displayInterfaceForRow(row)
  interfaceGateway.value = displayIface.gateway ?? ''
  interfaceDNS.value = (displayIface.dns ?? []).join(', ')
  if (!readinessByHost.value[row.hostId]) {
    void fetchHostReadiness(devicesStore.deviceByHostId(row.hostId))
  }
})

function interfacesForHost(hostId: string): HostInterface[] {
  if (useHomeUnion.value) return homeNets.interfacesFor(hostId)
  return localInterfaces.value
}

function interfaceReadinessFor(row: InterfaceTableRow) {
  return readinessByHost.value[row.hostId] ?? null
}

function displayInterfaceForRow(row: InterfaceTableRow): HostInterface {
  return effectiveInterfaceForDisplay(
    row.iface,
    interfacesForHost(row.hostId),
    interfaceReadinessFor(row),
    interfaceModeFor(row),
  )
}

function interfaceModeFor(row: InterfaceTableRow) {
  const device = devicesStore.deviceByHostId(row.hostId)
  return device ? deviceBridgeGuideMode(device) : 'hidden'
}

function interfaceBridgeInfo(row: InterfaceTableRow) {
  return getBridgeStatus(row.iface.name, row.hostId)
}

async function recheckSelectedInterface() {
  const row = selectedInterfaceRow.value
  if (!row) return
  linuxReadinessLoading.value = true
  try {
    await fetchHostReadiness(devicesStore.deviceByHostId(row.hostId))
    await refreshInterfaceContext(row.hostId)
  } finally {
    linuxReadinessLoading.value = false
  }
}

async function refreshInterfaceContext(hostId: string) {
  const device = devicesStore.deviceByHostId(hostId)
  if (device && useHomeUnion.value) {
    await homeNets.fetchContext(device)
    return
  }
  await fetchLocalInterfaces()
  if (bridged.available) await fetchLocalBridges()
}

function applyPayloadForSelectedInterface(): {
  rows: EditableHostAddress[]
  gateway: string
  dns: string
} {
  const row = selectedInterfaceRow.value
  if (!row) return { rows: [], gateway: '', dns: '' }
  if (showAddressEditor.value) {
    return {
      rows: interfaceEditRows.value,
      gateway: interfaceGateway.value,
      dns: interfaceDNS.value,
    }
  }
  const members = selectedBridgeMembers.value
  const memberRow = interfaceTableRows.value.find(
    (item) => item.hostId === row.hostId && members.includes(item.iface.name),
  )
  if (memberRow) {
    const display = displayInterfaceForRow(memberRow)
    return {
      rows: addressesFromInterface(display),
      gateway: display.gateway ?? '',
      dns: (display.dns ?? []).join(', '),
    }
  }
  return { rows: interfaceEditRows.value, gateway: interfaceGateway.value, dns: interfaceDNS.value }
}

async function runInterfaceHostBridge(action: 'apply' | 'revert' | 'delete', confirm = false) {
  const row = selectedInterfaceRow.value
  if (!row) return
  const device = devicesStore.deviceByHostId(row.hostId)
  if (homeUnionDeviceBlocked(device)) {
    toast.error('Device is unreachable. Workloads on this Device keep running locally.')
    return
  }
  if (action === 'apply' && showAddressEditor.value && !interfaceAddressValidation.value.ok) {
    toast.error(interfaceAddressValidation.value.errors[0] || 'Fix address list before applying.')
    return
  }
  if (action === 'delete' && selectedInterfaceDeleteBlocked.value) {
    toast.error('Cannot delete this Bridge: Workloads still reference it.')
    return
  }
  linuxApplySource.value = 'drawer'
  linuxApplyResult.value = null
  linuxApplyLoading.value = true
  try {
    const ready = readinessByHost.value[row.hostId]
    const nic = resolveBridgeApplyNic(row.iface, ready)
    const payload = applyPayloadForSelectedInterface()
    const path = device && useHomeUnion.value ? deviceBridgesPath(device) : '/system/bridges'
    const targetBridge = pendingCommit.value?.target
      ?? interfaceAssociatedBridge(row.iface, selectedInterfaceReadiness.value)?.name
      ?? selectedInterfaceReadiness.value?.suggestedBridge
    const data = action === 'revert'
      ? await api.delete<BridgeActionResponse>(
        hostBridgeRevertPath(
          nic,
          device ?? undefined,
          targetBridge,
        ),
        {
          data: {
            confirm,
            action: 'revert',
            interface: nic,
            bridge: targetBridge,
          },
        },
      ).then((r) => r.data)
      : action === 'delete'
        ? await api.post<BridgeActionResponse>(path, {
          confirm,
          action: 'delete',
          interface: nic,
          bridge: targetBridge,
        }).then((r) => r.data)
      : await api.post<BridgeActionResponse>(path, buildHostBridgeApplyBody({
        nic,
        bridge: selectedInterfaceRole.value === 'bridge' ? nic : undefined,
        confirm,
        rows: payload.rows,
        gateway: payload.gateway,
        dns: payload.dns,
      })).then((r) => r.data)
    linuxApplyResult.value = data
    if (data.needsConfirm && !confirm) {
      linuxApplyConfirm.value = action
      return
    }
    if (data.pendingCommit && data.commitDeadline && (action === 'apply' || action === 'delete')) {
      setPendingCommitFromResponse(row.hostId, nic, data)
    } else if (action === 'revert' || action === 'apply' || action === 'delete') {
      if (pendingCommit.value?.hostId === row.hostId) clearPendingCommitState()
    }
    if (data.success) {
      toast.success(data.message || (action === 'revert' ? 'Reverted host network.' : action === 'delete' ? 'Deleted host Bridge.' : 'Applied host network.'))
      await fetchHostReadiness(device)
      await refreshInterfaceContext(row.hostId)
      const refreshed = interfaceTableRows.value.find((item) => item.key === row.key)
      if (refreshed) {
        interfaceEditRows.value = addressesFromInterface(displayInterfaceForRow(refreshed))
        interfaceGateway.value = displayInterfaceForRow(refreshed).gateway ?? ''
        interfaceDNS.value = (displayInterfaceForRow(refreshed).dns ?? []).join(', ')
      }
    } else if (data.message) {
      toast.error(data.message)
    }
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    linuxApplyLoading.value = false
  }
}

function applySelectedInterface() {
  void runInterfaceHostBridge('apply')
}

function revertSelectedInterface() {
  void runInterfaceHostBridge('revert')
}

function deleteSelectedInterface() {
  void runInterfaceHostBridge('delete')
}

const selectedInterfaceShowsDelete = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row) return false
  return interfaceShowsDelete(row.iface, selectedInterfaceReadiness.value)
})

const selectedInterfaceDeleteBlocked = computed(() => {
  const row = selectedInterfaceRow.value
  if (!row) return false
  const associated = interfaceAssociatedBridge(row.iface, selectedInterfaceReadiness.value)
  const bridge = associated?.name
    ?? pendingCommit.value?.target
    ?? selectedInterfaceReadiness.value?.suggestedBridge
  if (!bridge) return false
  return homeRows.value.some((item) => (
    item.hostId === row.hostId
    && item.network.bridge === bridge
    && attachedWorkloads(item).length > 0
  ))
})

async function openBridgeSetupForPending(item: PendingBridge) {
  activeTab.value = 'interfaces'
  const device = devicesStore.deviceByHostId(item.hostId)
  const mode = device ? deviceBridgeGuideMode(device) : 'hidden'
  if (!readinessByHost.value[item.hostId]) {
    linuxReadinessLoading.value = true
    try {
      await fetchHostReadiness(device)
    } finally {
      linuxReadinessLoading.value = false
    }
  }
  const ready = readinessByHost.value[item.hostId]
  const targetKey = bridgeSetupInterfaceKey(item.hostId, ready, mode)
  if (targetKey && interfaceTableRows.value.some((row) => row.key === targetKey)) {
    selectedInterfaceKey.value = targetKey
    return
  }
  const fallback = interfaceTableRows.value.find((row) => {
    if (row.hostId !== item.hostId) return false
    const role = inferInterfaceRole(row.iface, readinessByHost.value[row.hostId], mode)
    return role === 'uplink' || role === 'bridge'
  })
  if (fallback) selectedInterfaceKey.value = fallback.key
}

function canMutate(row: HomeNetworkRow): boolean {
  return row.reachable && !row.network.isDefault
}

function defaultFormHostId(): string {
  if (!deviceScope.isAll) return deviceScope.selectedHostId
  return devicesStore.selfDevice?.hostId
    || devicesStore.devices.find((device) => canCallDeviceAPI(device))?.hostId
    || ''
}

function getBridgeStatus(ifaceName: string, hostId?: string): BridgeInfo | undefined {
  const list = hostId && useHomeUnion.value ? homeNets.bridgesFor(hostId) : bridges.value
  return list.find((b) => b.interface === ifaceName)
}

function getBridgeStatusForNetwork(row: HomeNetworkRow): string | null {
  const n = row.network
  if (n.mode !== 'bridged' || !n.bridge) return null
  const info = getBridgeStatus(n.bridge, row.hostId)
  return info?.status || 'not_configured'
}

function bridgeBadgeClass(status: string): string {
  if (status === 'active') return 'badge-green'
  if (status === 'installed') return 'badge-accent'
  return 'badge-gray'
}

function bridgeBadgeLabel(status: string): string {
  if (status === 'active') return 'active'
  if (status === 'installed') return 'installed'
  return 'no bridge'
}

const usedBridgeInterfaces = computed(() => {
  const used = new Map<string, string>()
  const nets = useHomeUnion.value && formHostId.value
    ? homeNets.networksFor(formHostId.value)
    : networks.value
  for (const n of nets) {
    if (n.mode === 'bridged' && n.bridge) {
      if (editingId.value && n.id === editingId.value) continue
      used.set(n.bridge, n.name)
    }
  }
  return used
})

const NAT_SUBNET = '10.0.2.0/24'
const NAT_GATEWAY = '10.0.2.2'
const NAT_DNS = '10.0.2.3'
const NAT_DHCP = '10.0.2.15 – 10.0.2.254'

function attachedWorkloads(row: HomeNetworkRow) {
  const rows = useHomeUnion.value
    ? homeWorkloads.homeRows(devicesStore.devices)
    : []
  return rows.filter((item) => {
    if (item.hostId !== row.hostId) return false
    if (row.network.isDefault && !item.vm.networkId) return true
    return item.vm.networkId === row.network.id
  })
}

function natSubnet(row: HomeNetworkRow): string {
  if (row.network.mode === 'nat') return NAT_SUBNET
  return '—'
}

function natGateway(row: HomeNetworkRow): string {
  if (row.network.mode === 'nat') return NAT_GATEWAY
  if (row.network.mode === 'bridged' && row.network.bridge) {
    return interfaceIp(row.network.bridge, row.hostId) || '—'
  }
  return '—'
}

function natDns(row: HomeNetworkRow): string {
  if (row.network.dnsServer) return row.network.dnsServer
  if (row.network.mode === 'nat') return NAT_DNS
  return '—'
}

function natDhcp(row: HomeNetworkRow): string {
  if (row.network.mode === 'nat') return NAT_DHCP
  return '—'
}

function modeCopy(row: HomeNetworkRow): string {
  if (row.network.mode === 'nat') return 'NAT — outbound only, shared Device address'
  if (row.network.mode === 'bridged') return 'Bridge — own LAN address'
  if (row.network.mode === 'isolated') return 'Isolated — private, no host/LAN/internet'
  return modeLabel(row.network.mode)
}

function deviceLine(row: HomeNetworkRow): string {
  return row.label
}

function workloadDot(row: ReturnType<typeof attachedWorkloads>[number]): string {
  const health = vmHealth(row.vm)
  if (health === 'failed') return 'bad'
  if (health === 'stopped' || health === 'unknown') return 'off'
  return 'ok'
}

function modeLabel(mode: string): string {
  const row = formNetworkModes.value.find((m) => m.mode === mode)
  if (row?.label) return row.label
  if (mode === 'nat') return 'NAT'
  if (mode === 'bridged') return 'Bridged (Home Network)'
  if (mode === 'isolated') return 'Isolated (Private)'
  return mode
}

const selectedModeRow = computed(() => formNetworkModes.value.find((m) => m.mode === newMode.value))

const typedBridgeMissing = computed(() => {
  if (newMode.value !== 'bridged' || !newBridge.value) return false
  return !formBridgePickerInterfaces.value.some((i) => i.name === newBridge.value)
})

const cannotSaveBridged = computed(() => newMode.value === 'bridged' && !formBridgedAvailable.value)

function interfaceIp(ifaceName: string, hostId?: string): string {
  const list = hostId && useHomeUnion.value ? homeNets.interfacesFor(hostId) : hostInterfaces.value
  return list.find((i) => i.name === ifaceName)?.ipAddress || ''
}

async function fetchLocalInterfaces() {
  try {
    const { data } = await api.get('/system/interfaces')
    localInterfaces.value = data
  } catch { /* keep last-known */ }
}

async function fetchLocalBridges() {
  try {
    const { data } = await api.get('/system/bridges')
    localBridges.value = data
  } catch { /* keep last-known */ }
}

async function probeInterfaceReadiness() {
  const devices = scopeRows(devicesStore.devices, deviceScope.selectedHostId)
  await Promise.all(devices.map(async (device) => {
    if (!canCallDeviceAPI(device)) return
    await fetchHostReadiness(device)
  }))
}

async function refreshHomeNetworks() {
  await devicesStore.fetchHealth().catch(() => {})
  if (!useHomeUnion.value) {
    const tasks: Promise<void>[] = [networkStore.fetchAll(), fetchLocalInterfaces()]
    if (bridged.available) tasks.push(fetchLocalBridges())
    await Promise.all(tasks)
    await probePendingReadiness()
    await probeInterfaceReadiness()
    return
  }
  await Promise.all([
    homeNets.fetchHomeAll(devicesStore.devices),
    homeWorkloads.fetchHomeAll(devicesStore.devices),
  ])
  await probePendingReadiness()
  await probeInterfaceReadiness()
}

async function loadFormContext() {
  const device = formDevice.value
  if (device && useHomeUnion.value) {
    await homeNets.fetchContext(device)
    return
  }
  await fetchLocalInterfaces()
  if (bridged.available) await fetchLocalBridges()
}

async function fetchHostReadiness(
  device: HomeDeviceHealthSnapshot | null,
): Promise<HostBridgeReadiness | null> {
  try {
    const path =
      device && useHomeUnion.value
        ? deviceHostBridgeReadinessPath(device)
        : '/system/host-bridge-readiness'
    const { data } = await api.get<HostBridgeReadiness>(path)
    const key = device?.hostId || devicesStore.selfDevice?.hostId || ''
    if (key) {
      readinessByHost.value = { ...readinessByHost.value, [key]: data }
      const nic = data.pendingCommit?.target
        ?? data.defaultRouteInterface
        ?? selectedInterfaceRow.value?.iface.name
        ?? ''
      if (nic) syncPendingCommitFromReadiness(key, data, nic)
    }
    return data
  } catch {
    return null
  }
}

async function probePendingReadiness() {
  const devices = scopeRows(devicesStore.devices, deviceScope.selectedHostId)
  await Promise.all(devices.map(async (device) => {
    if (!canCallDeviceAPI(device)) return
    const capsFor = deviceCapsFor(device.hostId)
    if (!capsFor.supportsBridgedNetworking) return
    const hasBridge = homeNets.networksFor(device.hostId).some((net) => net.mode === 'bridged')
    if (hasBridge) return
    await fetchHostReadiness(device)
  }))
}

function mutateTarget(hostId: string): HomeDeviceHealthSnapshot | null {
  return devicesStore.deviceByHostId(hostId)
    ?? (hostId ? null : devicesStore.selfDevice)
}

/** Home union must not fall back to the local host when the Device is gone. */
function homeUnionDeviceBlocked(device: HomeDeviceHealthSnapshot | null): boolean {
  return useHomeUnion.value && (!device || !canCallDeviceAPI(device))
}

onMounted(() => {
  void caps.fetchCapabilities().then(() => refreshHomeNetworks())
})

onUnmounted(() => {
  stopPendingCommitTimer()
})

watch(formHostId, async (id, prev) => {
  if (!showCreate.value || editingId.value || !id || id === prev) return
  await loadFormContext()
  if (newMode.value === 'bridged' && !formBridgedAvailable.value) {
    newMode.value = 'nat'
    newBridge.value = ''
  }
  if (newBridge.value && !formBridgePickerInterfaces.value.some((iface) => iface.name === newBridge.value)) {
    newBridge.value = ''
  }
})

async function confirmLinuxBridge() {
  const action = linuxApplyConfirm.value
  linuxApplyConfirm.value = null
  if (!action) return
  if (linuxApplySource.value === 'create-bridge') {
    await applyCreateBridge(true)
    return
  }
  await runInterfaceHostBridge(action, true)
}

function resetCreateBridgeForm() {
  createBridgeHostId.value = defaultFormHostId()
  createBridgeName.value = ''
  createBridgeNic.value = ''
  createBridgeRows.value = [{ id: 'dhcp', kind: 'dhcp', cidr: '' }]
  createBridgeGateway.value = ''
  createBridgeDNS.value = ''
  createBridgeVmNetwork.value = true
  createBridgeError.value = ''
}

async function fetchNextBridgeName(device: HomeDeviceHealthSnapshot | null) {
  const fallback = nextFreeBridgeName(takenBridgeNames(
    createBridgeIfaces.value,
    createBridgeReadiness.value,
  ))
  try {
    const path = device && useHomeUnion.value
      ? deviceBridgesNextPath(device)
      : '/system/bridges/next'
    const { data } = await api.get<NextBridgeResponse>(path)
    createBridgeName.value = data.bridge || fallback
  } catch {
    createBridgeName.value = fallback
  }
}

async function openCreateBridge() {
  createMenuOpen.value = false
  resetCreateBridgeForm()
  showCreateBridge.value = true
  const device = createBridgeDevice.value
  if (device && useHomeUnion.value) await homeNets.fetchContext(device)
  else await fetchLocalInterfaces()
  await fetchHostReadiness(device)
  await fetchNextBridgeName(device)
  if (!createBridgeNic.value) {
    createBridgeNic.value = defaultUnusedPort(createBridgePorts.value, createBridgeReadiness.value)
  }
}

watch(createBridgeHostId, async (id, prev) => {
  if (!showCreateBridge.value || !id || id === prev) return
  const device = devicesStore.deviceByHostId(id)
  if (device && useHomeUnion.value) await homeNets.fetchContext(device)
  await fetchHostReadiness(device)
  await fetchNextBridgeName(device)
  createBridgeNic.value = defaultUnusedPort(createBridgePorts.value, createBridgeReadiness.value)
})

async function applyCreateBridge(confirm = false) {
  createBridgeError.value = ''
  const nic = createBridgeNic.value
  const bridge = createBridgeName.value.trim()
  if (!bridge) {
    createBridgeError.value = 'Bridge name required'
    return
  }
  if (!nic) {
    createBridgeError.value = 'Select one unused NIC'
    return
  }
  if (!createBridgeAddressValidation.value.ok) {
    createBridgeError.value = createBridgeAddressValidation.value.errors[0] || 'Fix address list before applying.'
    return
  }
  const device = createBridgeDevice.value
  if (homeUnionDeviceBlocked(device)) {
    createBridgeError.value = 'Device is unreachable. Workloads on this Device keep running locally.'
    return
  }
  const platform = createBridgeCaps.value.platform
  const port = createBridgeIfaces.value.find((iface) => iface.name === nic)
  if (port && linuxRefusesWifiPort(port, platform)) {
    createBridgeError.value = 'Refuse Wi-Fi as port. Bridge a wired NIC.'
    return
  }
  linuxApplySource.value = 'create-bridge'
  linuxApplyResult.value = null
  linuxApplyLoading.value = true
  try {
    const path = device && useHomeUnion.value ? deviceBridgesPath(device) : '/system/bridges'
    const { data } = await api.post<BridgeActionResponse>(path, buildHostBridgeApplyBody({
      nic,
      bridge,
      confirm,
      rows: createBridgeRows.value,
      gateway: createBridgeGateway.value,
      dns: createBridgeDNS.value,
    }))
    linuxApplyResult.value = data
    if (data.needsConfirm && !confirm) {
      linuxApplyConfirm.value = 'apply'
      return
    }
    if (data.pendingCommit && data.commitDeadline) {
      const hostId = device?.hostId || devicesStore.selfDevice?.hostId || ''
      if (hostId) setPendingCommitFromResponse(hostId, nic, data)
    }
    if (data.success) {
      if (createBridgeVmNetwork.value) {
        const body: NetworkWriteBody = {
          name: `Bridged (${bridge})`,
          mode: 'bridged',
          bridge,
        }
        if (useHomeUnion.value && device) await homeNets.create(device, body)
        else await networkStore.create(body)
      }
      toast.success(data.message || `Created Bridge ${bridge}.`)
      showCreateBridge.value = false
      const hostId = device?.hostId || devicesStore.selfDevice?.hostId || ''
      if (hostId) {
        selectedInterfaceKey.value = `${hostId}:${nic}`
        await fetchHostReadiness(device)
        await refreshInterfaceContext(hostId)
      }
    } else if (data.message) {
      createBridgeError.value = data.message
    }
  } catch (e: unknown) {
    createBridgeError.value = apiErrorMessage(e)
  } finally {
    linuxApplyLoading.value = false
  }
}

function resetForm() {
  newName.value = ''
  newMode.value = 'nat'
  newBridge.value = ''
  newDns.value = ''
  error.value = ''
  editingId.value = null
  formHostId.value = defaultFormHostId()
}

function openCreate() {
  resetForm()
  showCreate.value = true
  void loadFormContext()
}

function openEdit(row: HomeNetworkRow) {
  const n = row.network
  const deviceCaps = homeNets.capsFor(row.hostId)
  const bridgedOk = deviceCaps?.supportsBridgedNetworking ?? n.mode === 'bridged'
  editingId.value = n.id
  formHostId.value = row.hostId
  newName.value = n.name
  newMode.value = n.mode === 'bridged' && !bridgedOk ? 'nat' : n.mode
  newBridge.value = n.mode === 'bridged' && bridgedOk ? (n.bridge || '') : ''
  newDns.value = n.dnsServer || ''
  error.value = ''
  showCreate.value = true
  void loadFormContext()
}

async function saveNetwork() {
  error.value = ''
  if (!newName.value.trim()) { error.value = 'Name required'; return }
  if (newMode.value === 'bridged' && !formBridgedAvailable.value) {
    error.value = formBridgedExplanation.value
    return
  }
  if (newMode.value === 'bridged' && !newBridge.value) {
    error.value = 'Bridge interface required for bridged mode'
    return
  }
  const device = formDevice.value
  if (homeUnionDeviceBlocked(device)) {
    error.value = 'Device is unreachable. Workloads on this Device keep running locally.'
    return
  }
  loading.value = true
  try {
    const body: NetworkWriteBody = {
      name: newName.value.trim(),
      mode: newMode.value,
      bridge: newMode.value === 'bridged' ? newBridge.value : '',
      dnsServer: (newMode.value === 'nat' || newMode.value === 'isolated')
        ? (newDns.value || (editingId.value ? '' : undefined))
        : undefined,
    }
    if (useHomeUnion.value && device) {
      if (editingId.value) await homeNets.update(device, editingId.value, body)
      else await homeNets.create(device, body)
    } else if (editingId.value) {
      await networkStore.update(editingId.value, body)
    } else {
      await networkStore.create(body)
    }
    showCreate.value = false
    resetForm()
  } catch (e: unknown) { error.value = apiErrorMessage(e) }
  finally { loading.value = false }
}

function deleteNetwork(row: HomeNetworkRow) {
  deleteTarget.value = { id: row.network.id, name: row.network.name, hostId: row.hostId }
}

async function doDeleteNetwork() {
  if (!deleteTarget.value) return
  deleting.value = true
  try {
    const device = mutateTarget(deleteTarget.value.hostId)
    if (homeUnionDeviceBlocked(device)) {
      toast.error('Device is unreachable. Workloads on this Device keep running locally.')
      return
    }
    if (useHomeUnion.value && device) {
      await homeNets.remove(device, deleteTarget.value.id)
    } else {
      await networkStore.remove(deleteTarget.value.id)
    }
  } catch (e: unknown) { toast.error(apiErrorMessage(e)) }
  finally {
    deleting.value = false
    deleteTarget.value = null
  }
}

</script>

<template>
  <div class="ops-page">
  <div class="ops-toolbar">
    <div class="ops-toolbar-main">
      <h1>Networks</h1>
      <span class="ops-sub">Connectivity across {{ HOME_LABEL }}</span>
      <div class="networks-seg" role="tablist" aria-label="Networks view">
        <button
          type="button"
          role="tab"
          class="networks-seg-btn"
          :class="{ on: activeTab === 'interfaces' }"
          :aria-selected="activeTab === 'interfaces'"
          @click="activeTab = 'interfaces'"
        >Host interfaces</button>
        <button
          type="button"
          role="tab"
          class="networks-seg-btn"
          :class="{ on: activeTab === 'vm' }"
          :aria-selected="activeTab === 'vm'"
          @click="activeTab = 'vm'"
        >VM networks</button>
      </div>
    </div>
    <div v-if="activeTab === 'interfaces'" class="ops-actions">
      <div class="create-menu">
        <AppButton variant="primary" icon="plus" @click="createMenuOpen = !createMenuOpen">Create</AppButton>
        <div v-if="createMenuOpen" class="create-menu-list">
          <button type="button" @click="openCreateBridge">Bridge</button>
        </div>
      </div>
    </div>
    <div v-if="activeTab === 'vm'" class="ops-actions">
      <AppButton variant="primary" icon="plus" @click="openCreate">Create Network</AppButton>
    </div>
  </div>

  <div
    class="ops-body"
    :class="{ split: activeTab === 'vm' && (homeRows.length > 0 || pendingBridges.length > 0) }"
  >

  <template v-if="activeTab === 'interfaces'">
    <p v-if="loadErrors.length" style="color:var(--red, #ef4444);font-size:13px;margin:0 0 12px">
      {{ loadErrors[0] }}
    </p>

    <EmptyState
      v-if="!pageLoading && interfaceTableRows.length === 0"
      icon="globe"
      title="No host interfaces on this Device"
      subtitle="Host interfaces are physical or virtual NICs on the Device (en0, eth0, br0). VM network records — NAT, bridged, isolated — are on the VM networks tab."
    />

    <template v-else-if="interfaceTableRows.length > 0">
      <DataTable
        :columns="[
          ...(showInterfaceDeviceColumn ? [{ key: 'device', label: DEVICE_LABEL }] : []),
          { key: 'interface', label: 'Interface' },
          { key: 'role', label: 'Role' },
          { key: 'link', label: 'Link' },
          { key: 'addresses', label: 'Addresses (live)' },
          { key: 'bridge', label: 'Bridge' },
          { key: 'route', label: 'Route' },
        ]"
      >
        <tr
          v-for="row in interfaceTableRows"
          :key="row.key"
          class="iface-row"
          :class="{ selected: selectedInterfaceKey === row.key }"
          @click="selectedInterfaceKey = row.key"
        >
          <td v-if="showInterfaceDeviceColumn">{{ row.deviceLabel }}</td>
          <td><strong class="mono">{{ row.iface.name }}</strong></td>
          <td>
            <span
              class="badge"
              :class="interfaceRoleBadgeClass(inferInterfaceRole(row.iface, interfaceReadinessFor(row), interfaceModeFor(row)))"
            >{{ interfaceRoleLabel(inferInterfaceRole(row.iface, interfaceReadinessFor(row), interfaceModeFor(row))) }}</span>
          </td>
          <td>{{ formatInterfaceLinkSummary(row.iface) }}</td>
          <td class="mono">{{ formatInterfaceAddressSummary(row.iface, interfaceReadinessFor(row), { mode: interfaceModeFor(row), allIfaces: interfacesForHost(row.hostId) }) }}</td>
          <td class="mono">{{ interfaceBridgeColumn(row.iface, interfaceReadinessFor(row), interfaceBridgeInfo(row), interfaceModeFor(row)) }}</td>
          <td>{{ interfaceRouteColumn(row.iface, interfaceReadinessFor(row)) }}</td>
        </tr>
      </DataTable>

      <section v-if="selectedInterfaceRow" class="iface-drawer sheet">
        <div class="sheet-head">
          <span>Edit {{ selectedInterfaceRow.iface.name }}</span>
          <span class="n">
            <template v-if="selectedInterfaceRole === 'bridge' && selectedInterfaceMode === 'linux-guide'">
              bridge · {{ selectedBridgeMembers.length ? `members ${selectedBridgeMembers.join(', ')}` : 'no member ports' }}
            </template>
            <template v-else>
              read from host · {{ (displayInterfaceForRow(selectedInterfaceRow).addresses?.length ?? 0) + (displayInterfaceForRow(selectedInterfaceRow).dhcpEnabled ? 1 : 0) }} addresses
            </template>
          </span>
        </div>
        <div class="iface-drawer-body">
          <p
            v-if="selectedInterfaceRole === 'bridge' && selectedInterfaceMode === 'linux-guide'"
            class="iface-drawer-hint"
          >
            IPv4 is configured on member port{{ selectedBridgeMembers.length === 1 ? '' : 's' }}
            {{ selectedBridgeMembers.length ? selectedBridgeMembers.join(', ') : '(none yet)' }}.
            Select a port row to edit addresses.
          </p>

          <HostInterfaceAddressList
            v-if="showAddressEditor"
            v-model="interfaceEditRows"
            :iface="displayInterfaceForRow(selectedInterfaceRow)"
            :only-uplink="selectedInterfaceReadiness?.onlyUplink"
            :gateway="interfaceGateway"
            :disabled="linuxApplyLoading || selectedInterfaceReadOnly"
          />

          <div v-if="showAddressEditor" class="iface-fields-grid">
            <div class="form-group">
              <label>Gateway</label>
              <input v-model="interfaceGateway" placeholder="192.168.1.1" spellcheck="false" :disabled="linuxApplyLoading || selectedInterfaceReadOnly" />
            </div>
            <div class="form-group">
              <label>DNS</label>
              <input v-model="interfaceDNS" placeholder="1.1.1.1, 8.8.8.8" spellcheck="false" :disabled="linuxApplyLoading || selectedInterfaceReadOnly" />
            </div>
          </div>

          <div class="iface-fields-grid">
            <div class="form-group">
              <label>Bridge role</label>
              <input
                :value="interfaceBridgeRoleDetail(selectedInterfaceRole, selectedInterfaceRow.iface, selectedInterfaceReadiness, selectedInterfaceMode)"
                readonly
                style="opacity:0.75"
              />
            </div>
          </div>

          <p
            v-if="interfaceBridgeStatusSummary"
            style="font-size:13px;margin:12px 0 0;color:var(--text-secondary)"
          >{{ interfaceBridgeStatusSummary }}</p>

          <details v-if="interfaceBridgeGuideGroups.length" class="iface-advanced">
            <summary>Advanced CLI (bridge setup)</summary>
            <GuestCommandAccordion
              :groups="interfaceBridgeGuideGroups"
              :initial-open="null"
            />
          </details>

          <div
            v-if="showPendingCommitBanner"
            class="iface-pending-commit"
            role="status"
            style="margin-top:12px;padding:12px 14px;border-radius:8px;border:1px solid var(--amber, #f59e0b);background:color-mix(in srgb, var(--amber, #f59e0b) 12%, transparent)"
          >
            <p style="margin:0 0 8px">
              Network changes are live but not permanent.
              <strong>{{ pendingCommitSecondsLeft }}s</strong> left — click Keep changes or they auto-revert.
            </p>
            <AppButton
              variant="primary"
              size="sm"
              :loading="linuxApplyLoading"
              @click="keepPendingCommit"
            >Keep changes</AppButton>
          </div>

          <div v-if="linuxApplyResult && activeTab === 'interfaces'" style="margin-top:12px;font-size:13px">
            <p style="margin:0 0 8px">{{ linuxApplyResult.message }}</p>
            <ul v-if="linuxApplyResult.changes?.length" style="margin:0;padding-left:18px">
              <li v-for="change in linuxApplyResult.changes" :key="change">{{ change }}</li>
            </ul>
          </div>

          <div class="iface-drawer-actions">
            <AppButton
              variant="primary"
              size="sm"
              :disabled="!canApplySelectedInterface || linuxApplyLoading || (showAddressEditor && !interfaceAddressValidation.ok)"
              :loading="linuxApplyLoading"
              @click="applySelectedInterface"
            >{{ applyButtonLabel }}</AppButton>
            <AppButton
              v-if="!selectedInterfaceShowsDelete"
              size="sm"
              :disabled="!canApplySelectedInterface || linuxApplyLoading"
              @click="revertSelectedInterface"
            >Revert</AppButton>
            <AppButton
              v-if="selectedInterfaceShowsDelete"
              size="sm"
              variant="danger"
              :disabled="!canApplySelectedInterface || linuxApplyLoading || selectedInterfaceDeleteBlocked"
              @click="deleteSelectedInterface"
            >Delete</AppButton>
            <p
              v-if="selectedInterfaceShowsDelete && selectedInterfaceDeleteBlocked"
              class="iface-drawer-hint"
            >Cannot delete this Bridge while Workloads still reference it.</p>
            <AppButton
              size="sm"
              :disabled="linuxReadinessLoading"
              @click="recheckSelectedInterface"
            >Re-check</AppButton>
          </div>

          <p class="iface-drawer-hint">
            Host interfaces are NICs on this Device. VM network records (NAT / bridged / isolated) are on the VM networks tab.
          </p>
        </div>
      </section>
    </template>
  </template>

  <template v-else-if="activeTab === 'vm'">
  <p class="vm-tab-intro">
    Workload networks are logical NAT, bridged, or isolated definitions Workloads attach to.
    Device addresses (NICs, DHCP, gateways) are on the Host interfaces tab.
  </p>
  <template v-if="homeRows.length > 0 || pendingBridges.length > 0">
  <section class="list-col">
    <div class="ops-sec-head"><h3>Workload networks</h3><span class="n">{{ homeRows.length + pendingBridges.length }}</span></div>
    <div class="list-scroll">
      <button
        v-for="row in homeRows"
        :key="rowKey(row)"
        type="button"
        class="nrow"
        :class="{ selected: selectedKey === rowKey(row) }"
        @click="selectedKey = rowKey(row)"
      >
        <div class="nrow-top">
          <span class="ops-dot" :class="row.reachable ? 'ok' : 'off'"></span>
          <span class="nrow-name">{{ row.network.name }}</span>
          <span v-if="row.network.isDefault" class="tag badge badge-accent">NAT</span>
          <span v-else class="tag">{{ modeLabel(row.network.mode) }}</span>
        </div>
        <div class="nrow-meta">
          {{ deviceLine(row) }} · {{ natSubnet(row) }} · {{ attachedWorkloads(row).length }} Workload{{ attachedWorkloads(row).length === 1 ? '' : 's' }}
        </div>
      </button>
      <button
        v-for="item in pendingBridges"
        :key="item.key"
        type="button"
        class="nrow pending"
        @click="openBridgeSetupForPending(item)"
      >
        <div class="nrow-top">
          <span class="ops-dot warn pulse"></span>
          <span class="nrow-name">Bridge</span>
          <span class="tag-amber">Pending</span>
        </div>
        <div class="nrow-meta">{{ item.label }} · configure on Host interfaces</div>
      </button>
    </div>
  </section>

  <section v-if="selectedRow" class="inspect">
    <p v-if="loadErrors.length" style="color:var(--red, #ef4444);font-size:13px;margin:0">
      {{ loadErrors[0] }}
    </p>

    <div class="detail-head">
      <div>
        <h2>{{ selectedRow.network.name }}</h2>
        <div class="detail-meta">
          Workload network · {{ deviceLine(selectedRow) }} ·
          <span class="ops-ok-text">{{ selectedRow.reachable ? 'Active' : 'Unreachable' }}</span>
        </div>
      </div>
      <div class="detail-head-actions">
        <AppButton v-if="canMutate(selectedRow)" size="sm" @click="openEdit(selectedRow)">Edit</AppButton>
        <AppButton v-if="canMutate(selectedRow)" size="sm" variant="danger" @click="deleteNetwork(selectedRow)">Delete</AppButton>
      </div>
      <div class="chips">
        <span class="chip">Mode <b>{{ modeLabel(selectedRow.network.mode) }}</b></span>
        <span class="chip">Subnet <b>{{ natSubnet(selectedRow) }}</b></span>
        <span class="chip">Workloads <b>{{ attachedWorkloads(selectedRow).length }}</b></span>
        <span v-if="selectedRow.network.isDefault" class="chip green">Default NAT</span>
      </div>
    </div>

    <div class="sheet">
      <div class="sheet-head">Configuration</div>
      <div class="fact">
        <span class="k">Mode</span>
        <span class="v">{{ modeCopy(selectedRow) }}</span>
      </div>
      <div class="fact">
        <span class="k">Subnet</span>
        <span class="v">{{ natSubnet(selectedRow) }}</span>
      </div>
      <div class="fact">
        <span class="k">Gateway</span>
        <span class="v">{{ natGateway(selectedRow) }}</span>
      </div>
      <div class="fact">
        <span class="k">DNS</span>
        <span class="v">{{ natDns(selectedRow) }}</span>
      </div>
      <div class="fact">
        <span class="k">DHCP range</span>
        <span class="v">{{ natDhcp(selectedRow) }}</span>
      </div>
      <div class="fact">
        <span class="k">{{ DEVICE_LABEL }}</span>
        <span class="v">{{ deviceLine(selectedRow) }}</span>
      </div>
    </div>

    <div v-if="selectedRow.network.mode === 'nat'" class="sheet">
      <div class="sheet-head">Port forwards</div>
      <div class="fwd-hint">
        Forwards are configured per Workload. Open a Workload → Network to publish a port, e.g. reachable as <code>localhost:port</code> on this {{ DEVICE_LABEL }}.
      </div>
    </div>

    <div class="sheet">
      <div class="sheet-head">Attached Workloads</div>
      <div v-if="attachedWorkloads(selectedRow).length === 0" class="fwd-hint">No Workloads on this network.</div>
      <div v-for="item in attachedWorkloads(selectedRow)" :key="item.vm.id" class="fact">
        <span class="k">{{ item.vm.name }}</span>
        <span class="v">
          <span class="ops-dot" :class="workloadDot(item)"></span>
          {{ healthLabel(vmHealth(item.vm)) }}
        </span>
      </div>
    </div>
  </section>

  </template>

  <template v-else>
  <p v-if="loadErrors.length" style="color:var(--red, #ef4444);font-size:13px;margin:0 0 12px">
    {{ loadErrors[0] }}
  </p>

  <EmptyState
    v-if="!pageLoading"
    icon="globe"
    title="No VM network records"
    subtitle="Workloads use the default NAT network until you create a VM network here. Host NICs and addresses are on the Host interfaces tab."
  />
  </template>
  </template>
  </div>

  <AppModal
    v-if="showCreateBridge"
    title="Create Bridge"
    subtitle="Create is the only path for a new switch. The server picks the next-free brN. One unused NIC is the port."
    rail-title="Bridge"
    @close="showCreateBridge = false"
  >
    <template #rail>
      <div class="split-s on">
        <span class="wizard-dot active">1</span>
        <div><div class="t">Port</div><div class="d">One unused NIC</div></div>
      </div>
      <div class="split-s">
        <span class="wizard-dot">2</span>
        <div><div class="t">Addressing</div><div class="d">On the new Bridge</div></div>
      </div>
      <div class="split-s">
        <span class="wizard-dot">3</span>
        <div><div class="t">VM network</div><div class="d">Optional Workload record</div></div>
      </div>
    </template>
    <div v-if="formDeviceOptions.length > 0" class="form-group">
      <label>{{ DEVICE_LABEL }}</label>
      <AppSelect v-model="createBridgeHostId" :options="formDeviceOptions" />
    </div>
    <div class="form-group">
      <label>Name</label>
      <input :value="createBridgeName" readonly />
    </div>
    <div class="form-group">
      <label>Port</label>
      <AppSelect v-model="createBridgeNic">
        <option value="" disabled>Select one unused NIC…</option>
        <option v-for="iface in createBridgePorts" :key="iface.name" :value="iface.name">
          {{ iface.name }}{{ iface.ipAddress ? ` (${iface.ipAddress})` : '' }}
        </option>
      </AppSelect>
      <p v-if="createBridgePorts.length === 0" style="color:var(--text-dim);font-size:12px;margin:6px 0 0">
        No unused NIC on this Device. Linux refuses Wi-Fi as a port.
      </p>
    </div>
    <HostInterfaceAddressList
      v-model="createBridgeRows"
      :only-uplink="createBridgeReadiness?.onlyUplink"
      :disabled="linuxApplyLoading"
    />
    <div class="iface-fields-grid">
      <div class="form-group">
        <label>Gateway</label>
        <input v-model="createBridgeGateway" placeholder="192.168.1.1" spellcheck="false" :disabled="linuxApplyLoading" />
      </div>
      <div class="form-group">
        <label>DNS</label>
        <input v-model="createBridgeDNS" placeholder="1.1.1.1, 8.8.8.8" spellcheck="false" :disabled="linuxApplyLoading" />
      </div>
    </div>
    <label class="create-bridge-vm">
      <input type="checkbox" v-model="createBridgeVmNetwork">
      <span>Create VM network</span>
    </label>
    <p style="color:var(--text-dim);font-size:12px;margin:6px 0 0">
      Default on. Adds a bridged Workload network with network.bridge set to this brN.
    </p>
    <FormError v-if="createBridgeError" :message="createBridgeError" />
    <template #actions>
      <AppButton @click="showCreateBridge = false">Cancel</AppButton>
      <AppButton
        variant="primary"
        :loading="linuxApplyLoading"
        :disabled="!createBridgeNic || !createBridgeAddressValidation.ok"
        :loading-text="'Applying...'"
        @click="applyCreateBridge()"
      >Apply</AppButton>
    </template>
  </AppModal>

  <!-- Create/Edit Network Modal -->
  <AppModal
    v-if="showCreate"
    :title="(editingId ? 'Edit' : 'Create') + ' Workload network'"
    subtitle="Workload networks are logical — NAT, bridged, or isolated. Device addresses (NICs) are on Host interfaces."
    rail-title="Workload network"
    @close="showCreate = false"
  >
    <template #rail>
      <div class="split-s on">
        <span class="wizard-dot active">1</span>
        <div><div class="t">Mode</div><div class="d">NAT / Bridge</div></div>
      </div>
      <div class="split-s">
        <span class="wizard-dot">2</span>
        <div><div class="t">Addressing</div><div class="d">NAT DNS · guest DHCP</div></div>
      </div>
    </template>
    <div v-if="formDeviceOptions.length > 0" class="form-group">
      <label>{{ DEVICE_LABEL }}</label>
      <AppSelect v-model="formHostId" :options="formDeviceOptions" :disabled="Boolean(editingId)" />
    </div>
    <div class="form-group"><label>Name</label><input v-model="newName" placeholder="my-network" /></div>
    <div class="form-group">
      <label>Mode</label>
      <AppSelect v-model="newMode">
        <option
          v-for="m in formNetworkModes"
          :key="m.mode"
          :value="m.mode"
          :disabled="!m.supported"
        >
          {{ modeLabel(m.mode) }}
        </option>
      </AppSelect>
      <p style="color:var(--text-dim);font-size:12px;margin:6px 0 0">
        Same names on Mac and Linux. Isolated is Private (no host/LAN/internet).
        Publish a service with NAT plus VM port forwards — not a fourth mode.
        A VM with no network selected uses NAT implicitly.
      </p>
      <UnsupportedHint
        v-if="selectedModeRow && !selectedModeRow.supported"
        :text="selectedModeRow.remediation || selectedModeRow.description || formBridgedExplanation"
      />
      <p
        v-else-if="selectedModeRow?.description"
        style="color:var(--text-dim);font-size:12px;margin:6px 0 0"
      >{{ selectedModeRow.description }}</p>
      <UnsupportedHint v-else-if="!formBridgedAvailable" :text="formBridgedExplanation" />
    </div>
    <div v-if="formBridgedAvailable && newMode === 'bridged'" class="form-group">
      <label>Host bridge interface</label>
      <AppSelect v-model="newBridge">
        <option value="" disabled>Select from Host interfaces…</option>
        <option v-for="iface in formBridgePickerInterfaces" :key="iface.name" :value="iface.name"
          :disabled="usedBridgeInterfaces.has(iface.name)">
          {{ iface.name }}{{ iface.ipAddress ? ` (${iface.ipAddress})` : '' }}{{ usedBridgeInterfaces.has(iface.name) ? ` — used by "${usedBridgeInterfaces.get(iface.name)}"` : iface.bridgeStatus === 'active' ? ' — active' : iface.bridgeStatus === 'installed' ? ' — installed' : '' }}
        </option>
      </AppSelect>
      <p style="color:var(--text-dim);font-size:12px;margin:6px 0 0">
        Same list as the Host interfaces tab. Configure the bridge and Device address there before starting bridged Workloads.
      </p>
      <p v-if="typedBridgeMissing" style="color:var(--text-secondary);font-size:12px;margin:6px 0 0">
        Interface "{{ newBridge }}" is not on this Device. Set it up on Host interfaces first — save and VM start will
        fail closed with a structured error instead of a QEMU log.
      </p>
    </div>
    <div v-if="newMode === 'nat' || newMode === 'isolated'" class="form-group">
      <label>DNS Server</label>
      <input v-model="newDns" placeholder="8.8.8.8 (optional)" />
    </div>
    <p v-if="newMode === 'bridged'" style="color:var(--text-dim);font-size:12px;margin:0">
      Bridged Workloads get a LAN address from your router (DHCP). Host bridge Device addressing is on the Host interfaces tab.
    </p>
    <FormError v-if="error" :message="error" />
    <template #actions>
      <AppButton @click="showCreate = false">Cancel</AppButton>
      <AppButton variant="primary" :loading="loading" :disabled="cannotSaveBridged" :loading-text="'Saving...'" @click="saveNetwork">{{ editingId ? 'Save' : 'Create' }}</AppButton>
    </template>
  </AppModal>

  <ConfirmDialog
    v-if="linuxApplyConfirm"
    title="Confirm host bridge change"
    :message="(linuxApplyResult?.warnings || []).join(' ') || 'This NIC may carry SSH or the SPA. After Apply you have 30 seconds to click Keep changes or the host auto-reverts.'"
    :confirm-label="linuxApplyConfirm === 'delete' ? 'Delete anyway' : linuxApplyConfirm === 'revert' ? 'Revert anyway' : 'Apply anyway'"
    :danger="true"
    :loading="linuxApplyLoading"
    @confirm="confirmLinuxBridge"
    @cancel="linuxApplyConfirm = null"
  />

  <ConfirmDialog
    v-if="deleteTarget"
    title="Delete Network"
    :message="`Delete network &quot;${deleteTarget.name}&quot;?`"
    confirm-label="Delete"
    :danger="true"
    :loading="deleting"
    @confirm="doDeleteNetwork"
    @cancel="deleteTarget = null"
  />
  </div>
</template>
