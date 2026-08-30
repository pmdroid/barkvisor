<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { ref, computed, onMounted, onUnmounted, watch } from 'vue'
import api from '../api/client'
import type { BridgeActionResponse, BridgeInfo, HomeDeviceHealthSnapshot, HostBridgeApplyRequest, HostBridgeReadiness, HostInterface } from '../api/types'
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
  deviceBridgesPath,
  deviceHostBridgeReadinessPath,
  isSelfDevice,
} from '../utils/homeDeviceApi'
import { HOST_BRIDGE_SUGGESTED } from '../utils/hostBridgeFacts'
import {
  hostBridgeApplyPayload,
  hostBridgeCanMutate,
  hostBridgeSetupPending,
  linuxBridgeFallbackReadiness,
  linuxBridgeSetupGroups,
  linuxBridgeStatusSummary,
  macosSocketVmnetSetupGroups,
  macosSocketVmnetStatusSummary,
  readinessAppliesTo,
} from '../utils/linuxBridgeSetup'
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
const managedBridge = useFeature('managedBridgeDaemon')
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

const showBridges = ref(false)
const bridgeHostId = ref('')

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

const contextHostId = computed(() => (showBridges.value ? bridgeHostId.value : formHostId.value))

const hostInterfaces = computed(() => {
  if (useHomeUnion.value && contextHostId.value) return homeNets.interfacesFor(contextHostId.value)
  return localInterfaces.value
})

const bridges = computed(() => {
  if (useHomeUnion.value && contextHostId.value) return homeNets.bridgesFor(contextHostId.value)
  return localBridges.value
})

const bridgeDevice = computed(() => {
  if (bridgeHostId.value) return devicesStore.deviceByHostId(bridgeHostId.value)
  return devicesStore.selfDevice
})

const bridgeCaps = computed(() => {
  if (useHomeUnion.value && bridgeHostId.value) {
    return deviceCapsFor(bridgeHostId.value)
  }
  return caps.currentHost
})

function deviceBridgeGuideMode(device: HomeDeviceHealthSnapshot) {
  const c = deviceCapsFor(device.hostId)
  return bridgeManagementMode({
    platform: c.platform || device.platform?.os,
    supportsHostBridgeManagement: c.supportsHostBridgeManagement,
    supportsManagedBridgeDaemon: c.supportsManagedBridgeDaemon,
  })
}

const selectedBridgeMode = computed(() => {
  const device = bridgeDevice.value
  if (device) return deviceBridgeGuideMode(device)
  return bridgeManagementMode({
    platform: caps.currentHost.platform,
    supportsHostBridgeManagement: caps.currentHost.supportsHostBridgeManagement,
    supportsManagedBridgeDaemon: caps.currentHost.supportsManagedBridgeDaemon,
  })
})

const canShowBridgeSetup = computed(() => {
  if (!useHomeUnion.value) {
    return bridgeManagementMode({
      platform: caps.currentHost.platform,
      supportsHostBridgeManagement: caps.currentHost.supportsHostBridgeManagement,
      supportsManagedBridgeDaemon: caps.currentHost.supportsManagedBridgeDaemon,
    }) !== 'hidden'
  }
  return devicesStore.devices.some((device) => {
    if (!canCallDeviceAPI(device)) return false
    return deviceBridgeGuideMode(device) !== 'hidden'
  })
})
const linuxReadiness = ref<HostBridgeReadiness | null>(null)
const linuxReadinessHostId = ref<string | null>(null)
const linuxReadinessMode = ref<string | null>(null)
const linuxReadinessLoading = ref(false)
const readinessByHost = ref<Record<string, HostBridgeReadiness>>({})
const pendingReadinessLoading = ref(false)
/** Newest host-bridge-readiness request; stale completions must not write. */
let readinessSeq = 0

const linuxApplyLoading = ref(false)
const linuxApplyResult = ref<BridgeActionResponse | null>(null)
const linuxApplyConfirm = ref<'apply' | 'revert' | null>(null)

const canMutateHostBridge = computed(() => hostBridgeCanMutate({
  platform: bridgeCaps.value.platform,
  supportsHostMutation: bridgeCaps.value.supportsHostMutation,
  supportsHostBridgeManagement: bridgeCaps.value.supportsHostBridgeManagement,
  supportsManagedBridgeDaemon: bridgeCaps.value.supportsManagedBridgeDaemon,
}))

const hostAddressing = ref<'dhcp' | 'static'>('dhcp')
const hostAddress = ref('')
const hostGateway = ref('')
const hostDns = ref('')

const appliedReadiness = computed(() => {
  if (!readinessAppliesTo(
    bridgeDevice.value?.hostId ?? '',
    linuxReadinessHostId.value,
    selectedBridgeMode.value,
    linuxReadinessMode.value,
  )) {
    return null
  }
  return linuxReadiness.value
})
const linuxSetupGroups = computed(() =>
  appliedReadiness.value ? linuxBridgeSetupGroups(appliedReadiness.value) : [],
)
const macosSetupGroups = computed(() => macosSocketVmnetSetupGroups(appliedReadiness.value))
const macosStatusSummary = computed(() => macosSocketVmnetStatusSummary(appliedReadiness.value))

const bridgeDeviceOptions = computed(() =>
  scopeRows(devicesStore.devices, deviceScope.selectedHostId)
    .filter((device) => canCallDeviceAPI(device))
    .map((device) => ({
      value: device.hostId,
      label: deviceDisplayLabel(device),
    })),
)

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
const selectedPending = computed(() =>
  pendingBridges.value.find((item) => item.key === selectedKey.value) ?? null,
)
const selectedPendingMode = computed(() => {
  const item = selectedPending.value
  if (!item) return 'hidden' as const
  const device = devicesStore.deviceByHostId(item.hostId)
  if (device) return deviceBridgeGuideMode(device)
  return 'hidden' as const
})
const pendingReadiness = computed(() => {
  const item = selectedPending.value
  if (!item) return null
  return readinessByHost.value[item.hostId] ?? null
})
const pendingLinuxFacts = computed(() => pendingReadiness.value ?? linuxBridgeFallbackReadiness)
const pendingLinuxGroups = computed(() => linuxBridgeSetupGroups(pendingLinuxFacts.value))
const pendingMacosGroups = computed(() => macosSocketVmnetSetupGroups(pendingReadiness.value))

watch([homeRows, pendingBridges], ([rows, pending]) => {
  if (!rows.length && !pending.length) {
    selectedKey.value = ''
    return
  }
  const keys = [
    ...rows.map((row) => rowKey(row)),
    ...pending.map((item) => item.key),
  ]
  if (!keys.includes(selectedKey.value)) {
    selectedKey.value = keys[0] ?? ''
  }
}, { immediate: true })

watch(selectedPending, (item) => {
  if (!item) return
  if (readinessByHost.value[item.hostId]) return
  pendingReadinessLoading.value = true
  void fetchHostReadiness(devicesStore.deviceByHostId(item.hostId)).finally(() => {
    pendingReadinessLoading.value = false
  })
})

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
  return !hostInterfaces.value.some((i) => i.name === newBridge.value)
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

async function refreshHomeNetworks() {
  await devicesStore.fetchHealth().catch(() => {})
  if (!useHomeUnion.value) {
    const tasks: Promise<void>[] = [networkStore.fetchAll(), fetchLocalInterfaces()]
    if (bridged.available) tasks.push(fetchLocalBridges())
    await Promise.all(tasks)
    await probePendingReadiness()
    return
  }
  await Promise.all([
    homeNets.fetchHomeAll(devicesStore.devices),
    homeWorkloads.fetchHomeAll(devicesStore.devices),
  ])
  await probePendingReadiness()
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

function discardReadinessForScope(hostId: string, mode: string): void {
  if (readinessAppliesTo(hostId, linuxReadinessHostId.value, mode, linuxReadinessMode.value)) return
  readinessSeq += 1
  linuxReadiness.value = null
  linuxReadinessHostId.value = hostId
  linuxReadinessMode.value = mode
}

async function loadBridgeContext() {
  const device = bridgeDevice.value
  const hostId = device?.hostId ?? ''
  const mode = selectedBridgeMode.value
  const showGuide = mode !== 'hidden'
  discardReadinessForScope(hostId, mode)
  if (showGuide) linuxReadinessLoading.value = true
  if (device && useHomeUnion.value) {
    await homeNets.fetchContext(device)
    if (showGuide) await fetchLinuxReadiness()
    return
  }
  await fetchLocalInterfaces()
  if (bridged.available || mode === 'macos-guide') await fetchLocalBridges()
  if (showGuide) await fetchLinuxReadiness()
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

async function recheckPending() {
  const item = selectedPending.value
  if (!item) return
  pendingReadinessLoading.value = true
  try {
    await fetchHostReadiness(devicesStore.deviceByHostId(item.hostId))
  } finally {
    pendingReadinessLoading.value = false
  }
}

async function fetchLinuxReadiness() {
  const device = bridgeDevice.value
  const requestHost = device?.hostId ?? ''
  const requestMode = selectedBridgeMode.value
  discardReadinessForScope(requestHost, requestMode)
  const seq = ++readinessSeq
  linuxReadinessLoading.value = true
  try {
    const data = await fetchHostReadiness(device)
    if (seq !== readinessSeq) return
    if (data) {
      linuxReadiness.value = data
      linuxReadinessHostId.value = requestHost
      linuxReadinessMode.value = requestMode
    }
  } catch {
    if (seq !== readinessSeq) return
  } finally {
    if (seq === readinessSeq) linuxReadinessLoading.value = false
  }
}

function mutateTarget(hostId: string): HomeDeviceHealthSnapshot | null {
  return devicesStore.deviceByHostId(hostId)
    ?? (hostId ? null : devicesStore.selfDevice)
}

/** Home union must not fall back to the local host when the Device is gone. */
function homeUnionDeviceBlocked(device: HomeDeviceHealthSnapshot | null): boolean {
  return useHomeUnion.value && (!device || !canCallDeviceAPI(device))
}

let bridgePoll: number | undefined

onMounted(() => {
  void caps.fetchCapabilities().then(() => refreshHomeNetworks())
})

watch(showBridges, (open) => {
  if (open) {
    if (!bridgeHostId.value) {
      const guided = devicesStore.devices.find((device) => {
        if (!canCallDeviceAPI(device)) return false
        return deviceBridgeGuideMode(device) !== 'hidden'
      })
      bridgeHostId.value = guided?.hostId || defaultFormHostId()
    }
    void loadBridgeContext()
    bridgePoll = window.setInterval(() => { void loadBridgeContext() }, 7000)
  } else if (bridgePoll) {
    clearInterval(bridgePoll)
    bridgePoll = undefined
  }
})

watch([bridgeHostId, selectedBridgeMode], () => {
  if (showBridges.value) void loadBridgeContext()
})

watch(formHostId, async (id, prev) => {
  if (!showCreate.value || editingId.value || !id || id === prev) return
  await loadFormContext()
  if (newMode.value === 'bridged' && !formBridgedAvailable.value) {
    newMode.value = 'nat'
    newBridge.value = ''
  }
  if (newBridge.value && !hostInterfaces.value.some((iface) => iface.name === newBridge.value)) {
    newBridge.value = ''
  }
})

onUnmounted(() => {
  if (bridgePoll) clearInterval(bridgePoll)
})

async function postLinuxBridge(body: HostBridgeApplyRequest): Promise<BridgeActionResponse> {
  const device = bridgeDevice.value
  const path = device && useHomeUnion.value ? deviceBridgesPath(device) : '/system/bridges'
  const { data } = await api.post<BridgeActionResponse>(path, body)
  return data
}

async function runLinuxBridge(action: 'apply' | 'revert', confirm = false) {
  linuxApplyResult.value = null
  linuxApplyLoading.value = true
  try {
    const nic = appliedReadiness.value?.defaultRouteInterface || undefined
    const data = action === 'revert'
      ? await api.delete<BridgeActionResponse>(
        (bridgeDevice.value && useHomeUnion.value
          ? `${deviceBridgesPath(bridgeDevice.value)}/br0`
          : '/system/bridges/br0'),
        { data: { confirm, action: 'revert' } },
      ).then((r) => r.data)
      : await postLinuxBridge(hostBridgeApplyPayload({
        nic,
        addressing: hostAddressing.value,
        address: hostAddress.value,
        gateway: hostGateway.value,
        dns: hostDns.value,
        confirm,
      }))
    linuxApplyResult.value = data
    if (data.needsConfirm && !confirm) {
      linuxApplyConfirm.value = action
      return
    }
    if (data.success) {
      toast.success(data.message || (action === 'revert' ? 'Reverted host bridge files.' : 'Applied host bridge.'))
      await fetchLinuxReadiness()
    } else if (data.message) {
      toast.error(data.message)
    }
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    linuxApplyLoading.value = false
  }
}

function applyLinuxBridge() {
  void runLinuxBridge('apply')
}

function revertLinuxBridge() {
  void runLinuxBridge('revert')
}

async function confirmLinuxBridge() {
  const action = linuxApplyConfirm.value
  linuxApplyConfirm.value = null
  if (!action) return
  await runLinuxBridge(action, true)
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
    <h1>Networks</h1>
    <span class="ops-sub">Connectivity across {{ HOME_LABEL }}</span>
    <div class="ops-actions">
      <span :title="canShowBridgeSetup ? undefined : (managedBridge.explanation || undefined)">
        <AppButton
          icon="settings"
          :disabled="!canShowBridgeSetup"
          @click="showBridges = true"
        >Bridge setup</AppButton>
      </span>
      <AppButton variant="primary" icon="plus" @click="openCreate">Create Network</AppButton>
    </div>
  </div>
  <div class="ops-body" :class="{ split: homeRows.length > 0 || pendingBridges.length > 0 }">

  <template v-if="homeRows.length > 0 || pendingBridges.length > 0">
  <section class="list-col">
    <div class="ops-sec-head"><h3>Networks</h3><span class="n">{{ homeRows.length + pendingBridges.length }}</span></div>
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
        :class="{ selected: selectedKey === item.key }"
        @click="selectedKey = item.key"
      >
        <div class="nrow-top">
          <span class="ops-dot warn pulse"></span>
          <span class="nrow-name">Bridge</span>
          <span class="tag-amber">Pending</span>
        </div>
        <div class="nrow-meta">{{ item.label }} · not configured</div>
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
        <div class="detail-meta">{{ deviceLine(selectedRow) }} · <span class="ops-ok-text">{{ selectedRow.reachable ? 'Active' : 'Unreachable' }}</span></div>
      </div>
      <div class="chips">
        <span class="chip">Mode <b>{{ modeLabel(selectedRow.network.mode) }}</b></span>
        <span class="chip">Subnet <b>{{ natSubnet(selectedRow) }}</b></span>
        <span class="chip">Workloads <b>{{ attachedWorkloads(selectedRow).length }}</b></span>
        <span v-if="selectedRow.network.isDefault" class="chip green">Default NAT</span>
      </div>
    </div>

    <div class="sheet">
      <div class="sheet-head">
        Configuration
        <AppButton v-if="canMutate(selectedRow)" size="sm" @click="openEdit(selectedRow)">Edit</AppButton>
      </div>
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

  <section v-else-if="selectedPending" class="inspect">
    <div class="detail-head">
      <div>
        <h2>Bridge</h2>
        <div class="detail-meta">{{ selectedPending.label }} · <span style="color:var(--amber);font-weight:600">Pending setup</span></div>
      </div>
      <div class="chips">
        <span class="chip">Mode <b>Bridge</b></span>
      </div>
    </div>
    <div class="ops-banner amber">
      <svg width="16" height="16" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.4"><path d="M7 1.5L13 12H1z" stroke-linejoin="round"/><path d="M7 5.5v3" stroke-linecap="round"/><circle cx="7" cy="10.2" r=".7" fill="currentColor" stroke="none"/></svg>
      <div>
        <div class="ops-banner-title">Bridge networking is not set up</div>
        <div class="ops-banner-sub">Workloads on a bridge get their own LAN addresses and are reachable from other machines.</div>
      </div>
    </div>
    <div class="sheet">
      <div class="sheet-head">
        Setup
        <AppButton size="sm" :disabled="pendingReadinessLoading" @click="recheckPending">Re-check</AppButton>
      </div>
      <p v-if="pendingReadinessLoading" style="color:var(--text-secondary);font-size:13px;margin:0">Checking this Device…</p>
      <template v-else-if="selectedPendingMode === 'linux-guide'">
        <p style="font-size:13px;margin:0 0 12px">{{ linuxBridgeStatusSummary(pendingLinuxFacts) }}</p>
        <ul v-if="pendingLinuxFacts.bridges.length" style="margin:0 0 12px;padding-left:18px;font-size:13px">
          <li v-for="br in pendingLinuxFacts.bridges" :key="br.name">
            <span class="mono">{{ br.name }}</span>
            <span v-if="br.enslaved.length" style="color:var(--text-secondary)">
              — {{ br.enslaved.join(', ') }}
            </span>
          </li>
        </ul>
        <GuestCommandAccordion
          v-if="pendingLinuxGroups.length"
          :groups="pendingLinuxGroups"
          :initial-open="pendingLinuxGroups[0]?.id ?? null"
        />
        <p v-if="pendingLinuxFacts.onlyUplink" style="color:var(--text-secondary);font-size:12px;margin-top:12px">
          Do not enslave the only uplink. Prefer NAT on this Device.
        </p>
      </template>
      <template v-else-if="selectedPendingMode === 'macos-guide'">
        <p style="font-size:13px;margin:0 0 12px">{{ macosSocketVmnetStatusSummary(pendingReadiness) }}</p>
        <ul v-if="pendingReadiness?.bridges.length" style="margin:0 0 12px;padding-left:18px;font-size:13px">
          <li v-for="br in (pendingReadiness?.bridges ?? [])" :key="br.name">
            <span class="mono">{{ br.name }}</span>
          </li>
        </ul>
        <GuestCommandAccordion
          v-if="pendingMacosGroups.length"
          :groups="pendingMacosGroups"
          :initial-open="pendingMacosGroups[0]?.id ?? null"
        />
      </template>
      <p v-else style="color:var(--text-secondary);font-size:13px;margin:0">
        Could not read host-bridge status on this Device.
      </p>
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
    title="No networks configured. VMs use NAT networking by default."
  />
  </template>
  </div>

  <!-- Bridge setup: Linux apply/revert; macOS socket_vmnet Setup/Start/Stop -->
  <AppModal v-if="showBridges" title="Bridge setup" max-width="800px" @close="showBridges = false">
    <div v-if="bridgeDeviceOptions.length > 0" class="form-group">
      <label>{{ DEVICE_LABEL }}</label>
      <AppSelect v-model="bridgeHostId" :options="bridgeDeviceOptions" />
    </div>
    <div v-if="selectedBridgeMode === 'linux-guide'" class="linux-bridge-guide">
      <p v-if="linuxReadinessLoading" style="color:var(--text-secondary);font-size:13px">Checking this Device…</p>
      <template v-else-if="appliedReadiness">
        <p style="font-size:13px;margin:0 0 12px">{{ linuxBridgeStatusSummary(appliedReadiness) }}</p>
        <ul v-if="appliedReadiness.bridges.length" style="margin:0 0 12px;padding-left:18px;font-size:13px">
          <li v-for="br in appliedReadiness.bridges" :key="br.name">
            <span class="mono">{{ br.name }}</span>
            <span v-if="br.enslaved.length" style="color:var(--text-secondary)">
              — {{ br.enslaved.join(', ') }}
            </span>
          </li>
        </ul>
        <GuestCommandAccordion
          v-if="linuxSetupGroups.length"
          :groups="linuxSetupGroups"
          :initial-open="linuxSetupGroups[0]?.id ?? null"
        />
        <p v-if="appliedReadiness.onlyUplink" style="color:var(--text-secondary);font-size:12px;margin-top:12px">
          Do not enslave the only uplink. Prefer NAT on this Device.
        </p>
        <div v-if="linuxApplyResult" style="margin-top:12px;font-size:13px">
          <p style="margin:0 0 8px">{{ linuxApplyResult.message }}</p>
          <ul v-if="linuxApplyResult.changes?.length" style="margin:0;padding-left:18px">
            <li v-for="change in linuxApplyResult.changes" :key="change">{{ change }}</li>
          </ul>
          <p
            v-for="warn in (linuxApplyResult.warnings ?? [])"
            :key="warn"
            style="color:var(--amber);margin:8px 0 0"
          >{{ warn }}</p>
        </div>
      </template>
      <p v-else style="color:var(--text-secondary);font-size:13px">
        Could not read host-bridge status on this Device.
      </p>
    </div>
    <div v-else-if="selectedBridgeMode === 'macos-guide'" class="linux-bridge-guide">
      <p v-if="linuxReadinessLoading" style="color:var(--text-secondary);font-size:13px">Checking this Device…</p>
      <template v-else>
        <p style="font-size:13px;margin:0 0 12px">{{ macosStatusSummary }}</p>
        <ul v-if="appliedReadiness?.bridges.length" style="margin:0 0 12px;padding-left:18px;font-size:13px">
          <li v-for="br in (appliedReadiness?.bridges ?? [])" :key="br.name">
            <span class="mono">{{ br.name }}</span>
          </li>
        </ul>
        <GuestCommandAccordion
          v-if="macosSetupGroups.length"
          :groups="macosSetupGroups"
          :initial-open="macosSetupGroups[0]?.id ?? null"
        />
        <div v-if="linuxApplyResult" style="margin-top:12px;font-size:13px">
          <p style="margin:0 0 8px">{{ linuxApplyResult.message }}</p>
          <ul v-if="linuxApplyResult.changes?.length" style="margin:0;padding-left:18px">
            <li v-for="change in linuxApplyResult.changes" :key="change">{{ change }}</li>
          </ul>
        </div>
        <DataTable
          v-if="hostInterfaces.length"
          style="margin-top:16px"
          :columns="[
            { key: 'interface', label: 'Interface' },
            { key: 'ip', label: 'IP' },
            { key: 'status', label: 'Status' },
          ]"
        >
          <tr v-for="iface in hostInterfaces" :key="iface.name">
            <td style="font-weight:500">
              {{ iface.name }}
              <div v-if="iface.displayName !== iface.name" style="color:var(--text-secondary);font-size:11px">{{ iface.displayName }}</div>
            </td>
            <td class="mono" style="color:var(--text-secondary)">{{ iface.ipAddress || '-' }}</td>
            <td>
              <span class="badge" :class="bridgeBadgeClass(getBridgeStatus(iface.name, bridgeHostId)?.status || 'not_configured')">
                {{ bridgeBadgeLabel(getBridgeStatus(iface.name, bridgeHostId)?.status || 'not_configured') }}
              </span>
            </td>
          </tr>
        </DataTable>
      </template>
    </div>
    <UnsupportedHint
      v-else
      :text="bridgeCaps.details?.find((d) => d.code === 'managedBridgeDaemon' && !d.supported)?.remediation || managedBridge.explanation"
    />
    <div v-if="canMutateHostBridge" class="form-group" style="margin-top:16px">
      <label>Device address</label>
      <div style="display:flex;gap:16px;flex-wrap:wrap;margin-top:6px">
        <label style="display:flex;gap:6px;align-items:center;font-size:13px">
          <input v-model="hostAddressing" type="radio" name="host-addressing" value="dhcp"> DHCP
        </label>
        <label style="display:flex;gap:6px;align-items:center;font-size:13px">
          <input v-model="hostAddressing" type="radio" name="host-addressing" value="static"> static
        </label>
      </div>
      <template v-if="hostAddressing === 'static'">
        <input v-model="hostAddress" style="margin-top:8px;width:100%" placeholder="192.168.1.10/24" />
        <input v-model="hostGateway" style="margin-top:8px;width:100%" placeholder="Gateway" />
        <input v-model="hostDns" style="margin-top:8px;width:100%" placeholder="1.1.1.1, 8.8.8.8" />
      </template>
    </div>
    <template #actions>
      <AppButton
        v-if="canMutateHostBridge"
        :disabled="linuxApplyLoading || linuxReadinessLoading"
        :loading="linuxApplyLoading"
        @click="applyLinuxBridge"
      >Apply</AppButton>
      <AppButton
        v-if="canMutateHostBridge"
        :disabled="linuxApplyLoading || linuxReadinessLoading"
        @click="revertLinuxBridge"
      >Revert</AppButton>
      <AppButton
        v-if="selectedBridgeMode !== 'hidden'"
        :disabled="linuxReadinessLoading"
        @click="fetchLinuxReadiness"
      >Re-check</AppButton>
      <AppButton @click="showBridges = false">Close</AppButton>
    </template>
  </AppModal>

  <!-- Create/Edit Network Modal -->
  <AppModal
    v-if="showCreate"
    :title="(editingId ? 'Edit' : 'Create') + ' Network'"
    subtitle="NAT is outbound only. Bridge gives each Workload a LAN address."
    rail-title="Network"
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
      <label>Bridge Interface</label>
      <AppSelect v-model="newBridge">
        <option value="" disabled>Select interface...</option>
        <option v-for="iface in hostInterfaces" :key="iface.name" :value="iface.name"
          :disabled="usedBridgeInterfaces.has(iface.name)">
          {{ iface.name }}{{ iface.ipAddress ? ` (${iface.ipAddress})` : '' }}{{ usedBridgeInterfaces.has(iface.name) ? ` — used by "${usedBridgeInterfaces.get(iface.name)}"` : iface.bridgeStatus === 'active' ? ' — active' : iface.bridgeStatus === 'installed' ? ' — installed' : '' }}
        </option>
      </AppSelect>
      <!-- Linux host bridges: allow typing a name not in the dropdown (e.g. no-IP br*). -->
      <template v-if="formCaps.supportsHostBridgeManagement">
        <input
          v-model="newBridge"
          class="bridge-custom"
          style="margin-top:8px;width:100%"
          :placeholder="`Or type bridge name (e.g. ${HOST_BRIDGE_SUGGESTED})`"
          spellcheck="false"
          autocomplete="off"
        />
        <p style="color:var(--text-dim);font-size:12px;margin:6px 0 0">
          Use an existing host bridge (e.g. br0). Apply it from Bridge setup before starting VMs.
          Bridges without an IP still appear when detected; you can also type the name.
        </p>
        <p v-if="typedBridgeMissing" style="color:var(--text-secondary);font-size:12px;margin:6px 0 0">
          Interface "{{ newBridge }}" is not on this Device. Create it first — save and VM start will
          fail closed with a structured error instead of a QEMU log.
        </p>
      </template>
    </div>
    <div v-if="newMode === 'nat' || newMode === 'isolated'" class="form-group">
      <label>DNS Server</label>
      <input v-model="newDns" placeholder="8.8.8.8 (optional)" />
    </div>
    <p v-if="newMode === 'bridged'" style="color:var(--text-dim);font-size:12px;margin:0">
      Bridged Workloads get a LAN address from your router (DHCP) unless you set a static IPv4 on the Workload. Host bridge addressing is not configured here.
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
    :message="(linuxApplyResult?.warnings || []).join(' ') || 'This NIC may carry SSH or the SPA. Rollback is a host timer, not a browser Confirm after the uplink dies.'"
    confirm-label="Apply anyway"
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
