<script setup lang="ts">
import { apiErrorMessage, isNotFoundError } from '../api/errors'
import { ref, onMounted, onUnmounted, computed, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useVMStore } from '../stores/vms'
import { useDevicesStore } from '../stores/devices'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import WorkloadDeviceChip from '../components/home/WorkloadDeviceChip.vue'
import api from '../api/client'
import {
  canFetchDeviceWorkloads,
  deviceCapabilitiesPath,
  deviceDiskUsagePath,
  devicePath,
  isSelfDevice,
} from '../utils/homeDeviceApi'
import { DEVICE_LABEL } from '../utils/terminology'
import { useTicketedEventSource } from '../composables/useTicketedEventSource'
import type {
  CurrentHostCapabilities,
  Disk,
  DiskUsage,
  GuestInfo,
  Image,
  Network,
  PortForwardRule,
  BridgeInfo,
  HostGPUDevice,
  HostUSBDevice,
  GPUPassthroughDevice,
  USBPassthroughDevice,
} from '../api/types'
import PortForwardEditor from '../components/PortForwardEditor.vue'
import { useToastStore } from '../stores/toast'
import ConsolePanel from '../components/ConsolePanel.vue'
import ChatPanel from '../components/ChatPanel.vue'
import VNCPanel from '../components/VNCPanel.vue'
import MetricsPanel from '../components/MetricsPanel.vue'
import LogsPanel from '../components/LogsPanel.vue'
import FolderPicker from '../components/FolderPicker.vue'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppIcon from '../components/ui/AppIcon.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import UnsupportedHint from '../components/ui/UnsupportedHint.vue'
import StopButtonGroup from '../components/ui/StopButtonGroup.vue'
import { formatBytes } from '../utils/format'
import { applyVMStateEvent, healthLabel, healthPillClass, vmHealth } from '../utils/workloadHealth'
import { acceleratorLabel, vmBackend } from '../utils/workloadBackend'
import { architectureLabel } from '../utils/architectureDetails'
import {
  isMemberWorkloadDetail,
  localNetworkForDetail,
  memberNetworkCaption,
  workloadDetailVmSource,
} from '../utils/workloadDetail'
import { guestInfoFetchPath, guestOsLabel } from '../utils/guestHome'
import {
  claimedNatTcpHostPorts,
  guestListeningPortAccessLabel,
  guestListeningPortHref,
  isPublishedGuestPort,
  suggestPublishNatHostfwd,
} from '../utils/guestListeningPorts'
import {
  guestAgentInstallCommands,
  guestAgentInstallOpenId,
  shouldShowGuestAgentInstall,
} from '../utils/guestAgentInstall'
import GuestCommandAccordion from '../components/ui/GuestCommandAccordion.vue'
import {
  disksInventoryFetchPath,
  isMemberControlTab,
  memberControlTabAllowed,
  memberNetworkForDetail,
  networksInventoryFetchPath,
  gpuInventoryFetchPath,
  usbInventoryFetchPath,
} from '../utils/editHome'
import { canConnectDeviceConsole, vncWindowPath } from '../utils/consoleHome'
import { parseSystemCapabilities } from '../utils/capabilitiesParse'
import { GUEST_OLLAMA_PATH, gpuHostOccupancyLabel, gpuPassthroughExplanation, gpuPassthroughSupported } from '../utils/gpuPassthrough'
import { isAgentWorkload, workloadGrantCopy, parseWorkloadClass } from '../utils/workloadClass'
import {
  consoleTabLabel,
  isCodingAgentSession,
  SESSION_NO_PUSH,
  sessionReceiptCopy,
  sessionWarningCopy,
} from '../utils/codingAgentSession'
import { chatIsVisible } from '../utils/chatCompletions'
import { useOllamaStore } from '../stores/ollama'
import { useCapabilitiesStore } from '../stores/capabilities'
import { useDiskStore } from '../stores/disks'
import { useNetworkStore } from '../stores/networks'
import { storeToRefs } from 'pinia'
import { useFeature } from '../composables/useFeature'

const route = useRoute()
const router = useRouter()
const store = useVMStore()
const devicesStore = useDevicesStore()
const homeWorkloads = useDeviceWorkloadsStore()
const caps = useCapabilitiesStore()
const diskStore = useDiskStore()
const networkStore = useNetworkStore()
const usb = useFeature('usbPassthrough')
const bridged = useFeature('bridgedNetworking')
const managedBridge = useFeature('managedBridgeDaemon')
const { disks: allDisks, usages: diskUsages } = storeToRefs(diskStore)
const { networks: allNetworks } = storeToRefs(networkStore)
const vmId = computed(() => route.params.id as string)
const hostId = computed(() => {
  const raw = route.params.hostId
  return raw ? String(raw) : ''
})
const memberLoadSettled = ref(false)
const memberLoadError = ref<string | null>(null)
const memberRole = computed(() => (
  hostId.value ? devicesStore.deviceByHostId(hostId.value)?.role : undefined
))
const isMemberDetail = computed(() => isMemberWorkloadDetail({
  hostId: hostId.value,
  role: memberRole.value,
  loadSettled: memberLoadSettled.value,
}))
const memberDevice = computed(() => (
  hostId.value ? devicesStore.deviceByHostId(hostId.value) : null
))
const memberReachable = computed(() => {
  const device = memberDevice.value
  return Boolean(device && canFetchDeviceWorkloads(device))
})
const showMemberConnect = computed(() => (
  !isMemberDetail.value || canConnectDeviceConsole(memberDevice.value)
))
const tab = ref((route.query.tab as string) || 'overview')

/** Open VNC in a dedicated resizable window (toolbar button, not tab side-effect). */
function openVncWindow() {
  if (vm.value?.state !== 'running' && vm.value?.state !== 'stopping') {
    toast.info('VM must be running to open VNC')
    return
  }
  if (isMemberDetail.value && !showMemberConnect.value) return
  const w = Math.min(1400, screen.availWidth - 40)
  const h = Math.min(900, screen.availHeight - 60)
  const left = Math.max(0, Math.floor((screen.availWidth - w) / 2))
  const top = Math.max(0, Math.floor((screen.availHeight - h) / 2))
  window.open(
    vncWindowPath(isMemberDetail.value ? memberDevice.value : undefined, vmId.value),
    `barkvisor-vnc-${vmId.value}`,
    `popup=yes,width=${w},height=${h},left=${left},top=${top},resizable=yes,scrollbars=no`,
  )
}

const vm = computed(() => {
  const source = workloadDetailVmSource({ hostId: hostId.value, role: memberRole.value })
  if (source === 'pending') return undefined
  if (source === 'member') return homeWorkloads.vmFor(hostId.value, vmId.value)
  return store.vms.find(v => v.id === vmId.value)
})

const agentCage = computed(() => isAgentWorkload(vm.value))
const grantCopy = computed(() => workloadGrantCopy(parseWorkloadClass(vm.value?.workloadClass ?? vm.value?.spec?.spec?.workloadClass)))
const ollamaStore = useOllamaStore()
const codingAgent = computed(() => isCodingAgentSession(vm.value))
const showAgentChat = computed(() => codingAgent.value && chatIsVisible(ollamaStore.anyReachable, ollamaStore.models.length))
const consoleLabel = computed(() => consoleTabLabel(vm.value))
const session = computed(() => vm.value?.session ?? null)
const sessionReceipt = computed(() => sessionReceiptCopy(session.value?.receipt, vm.value?.state))
const showResetDialog = ref(false)
const showBurnDialog = ref(false)

function memberTabPermitted(value: string): boolean {
  if (!isMemberControlTab(value)) return false
  if ((value === 'console' || value === 'vnc') && !showMemberConnect.value) return false
  if (!vm.value) return true
  return memberControlTabAllowed(value, vm.value.state)
}

watch(isMemberDetail, (remote) => {
  if (remote && !memberTabPermitted(tab.value)) tab.value = 'overview'
}, { immediate: true })

watch(showMemberConnect, (ok) => {
  if (!isMemberDetail.value || !memberDevice.value) return
  if (!ok && (tab.value === 'console' || tab.value === 'vnc')) tab.value = 'overview'
})

watch(showAgentChat, (ok) => {
  if (!ok && tab.value === 'chat') tab.value = 'overview'
})

watch(tab, (value) => {
  if (isMemberDetail.value && !memberTabPermitted(value)) {
    tab.value = 'overview'
    return
  }
  router.replace({ query: { ...route.query, tab: value === 'overview' ? undefined : value } })
})

watch(() => vm.value?.state, (state) => {
  if (!isMemberDetail.value || state === undefined) return
  if (!memberControlTabAllowed(tab.value, state)) tab.value = 'overview'
})

const actionLoading = ref('')
const controlDisabled = computed(() => (
  Boolean(actionLoading.value) || (isMemberDetail.value && !memberReachable.value)
))
const showEditModal = ref(false)
const editDraft = ref({
  description: '',
  cpuCount: 1,
  memoryMB: 512,
  bootOrder: 'cd',
  networkId: '',
})
const editSaving = ref(false)

// Disk management (list from shared store)
const showAttachDisk = ref(false)
const attachLoading = ref(false)

// Network management (list from shared store)
const bridges = ref<BridgeInfo[]>([])
const bridgeLoading = ref<string | null>(null)

// Guest agent info (includes IP, OS, filesystem, etc.)
const guestInfo = ref<GuestInfo | null>(null)
const guestInfoLoaded = ref(false)

// USB passthrough
const hostUSBDevices = ref<HostUSBDevice[]>([])
const showAttachUSB = ref(false)
const usbLoading = ref(false)
const hostGPUDevices = ref<HostGPUDevice[]>([])
const showAttachGPU = ref(false)
const gpuLoading = ref(false)

const memberDisks = ref<Disk[]>([])
const memberDiskUsages = ref<Record<string, DiskUsage>>({})
const memberNetworks = ref<Network[]>([])
const memberImages = ref<Image[]>([])
const memberCaps = ref<CurrentHostCapabilities | null>(null)

const detailDisks = computed(() => (isMemberDetail.value ? memberDisks.value : allDisks.value))
const detailDiskUsages = computed(() => (
  isMemberDetail.value ? memberDiskUsages.value : diskUsages.value
))
const detailNetworks = computed(() => (
  isMemberDetail.value ? memberNetworks.value : allNetworks.value
))
const detailImages = computed(() => (isMemberDetail.value ? memberImages.value : allImages.value))
const memberUsbAvailable = computed(() => memberCaps.value?.supportsUSBPassthrough === true)
const memberUsbExplanation = computed(() => (
  memberCaps.value?.details?.find((d) => d.code === 'usbPassthrough' && !d.supported)?.remediation
  || undefined
))
const usbAvailable = computed(() => (
  isMemberDetail.value ? memberUsbAvailable.value : usb.available
))
const usbExplanation = computed(() => (
  isMemberDetail.value ? memberUsbExplanation.value : usb.explanation
))
const gpuCaps = computed(() => (
  isMemberDetail.value ? memberCaps.value : caps.currentHost
))
const gpuReady = computed(() => gpuPassthroughSupported(gpuCaps.value))
const gpuExplanation = computed(() => gpuPassthroughExplanation(gpuCaps.value))
const editCpuMax = computed(() => {
  if (isMemberDetail.value) {
    const n = memberCaps.value?.hostCpuCount
    return typeof n === 'number' && n >= 1 ? n : undefined
  }
  return caps.hostCpuCount
})

// Port forwards
const showPortForwardEditor = ref(false)
const editPortForwards = ref<PortForwardRule[]>([])
const pfSaving = ref(false)

function openPortForwardEditor(draft?: PortForwardRule) {
  const current = vm.value?.portForwards ? [...vm.value.portForwards] : []
  if (draft && typeof draft.hostPort === 'number' && typeof draft.guestPort === 'number') {
    current.push({ ...draft })
  }
  editPortForwards.value = current
  showPortForwardEditor.value = true
}

async function savePortForwards() {
  pfSaving.value = true
  try {
    await patchWorkload({ portForwards: editPortForwards.value } as any)
    showPortForwardEditor.value = false
    await refreshWorkload()
    if (vm.value?.state === 'running') {
      toast.show('Port forward changes require a VM restart to take effect.', { type: 'info' })
    }
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    pfSaving.value = false
  }
}

const availableDisks = computed(() => {
  if (!vm.value) return []
  const attached = new Set([vm.value.bootDiskId, ...(vm.value.additionalDiskIds || [])])
  return detailDisks.value.filter(d => !attached.has(d.id))
})

const additionalDiskDetails = computed(() => {
  if (!vm.value?.additionalDiskIds) return []
  return vm.value.additionalDiskIds
    .map(diskId => detailDisks.value.find(d => d.id === diskId))
    .filter(Boolean) as Disk[]
})

// Images (for ISO name lookup)
const allImages = ref<Image[]>([])

let memberInventoryHostId = ''

function resetMemberInventory() {
  memberInventoryHostId = ''
  memberDisks.value = []
  memberDiskUsages.value = {}
  memberNetworks.value = []
  memberImages.value = []
  memberCaps.value = null
  hostUSBDevices.value = []
  hostGPUDevices.value = []
}

async function fetchMemberInventory() {
  const device = memberDevice.value
  if (!device || !canFetchDeviceWorkloads(device)) {
    resetMemberInventory()
    return
  }
  const host = device.hostId
  const stillThisDevice = () => memberDevice.value?.hostId === host
  const disksPath = disksInventoryFetchPath(device)
  const netsPath = networksInventoryFetchPath(device)
  const usbPath = usbInventoryFetchPath(device)
  const gpuPath = gpuInventoryFetchPath(device)
  await Promise.all([
    disksPath
      ? api.get<Disk[]>(disksPath).then(({ data }) => {
          if (!stillThisDevice()) return
          memberDisks.value = Array.isArray(data) ? data : []
        }).catch(() => {})
      : Promise.resolve(),
    netsPath
      ? api.get<Network[]>(netsPath).then(({ data }) => {
          if (!stillThisDevice()) return
          memberNetworks.value = Array.isArray(data) ? data : []
        }).catch(() => {})
      : Promise.resolve(),
    usbPath
      ? api.get<HostUSBDevice[]>(usbPath).then(({ data }) => {
          if (!stillThisDevice()) return
          hostUSBDevices.value = Array.isArray(data) ? data : []
        }).catch(() => {
          if (!stillThisDevice()) return
          hostUSBDevices.value = []
        })
      : Promise.resolve(),
    gpuPath
      ? api.get<HostGPUDevice[]>(gpuPath).then(({ data }) => {
          if (!stillThisDevice()) return
          hostGPUDevices.value = Array.isArray(data) ? data : []
        }).catch(() => {
          if (!stillThisDevice()) return
          hostGPUDevices.value = []
        })
      : Promise.resolve(),
    api.get(deviceCapabilitiesPath(device)).then(({ data }) => {
      if (!stillThisDevice()) return
      memberCaps.value = parseSystemCapabilities(data)
    }).catch(() => {}),
    api.get<Image[]>(devicePath(device, '/images')).then(({ data }) => {
      if (!stillThisDevice()) return
      memberImages.value = Array.isArray(data) ? data : []
    }).catch(() => {}),
  ])
  if (!stillThisDevice()) return
  memberInventoryHostId = host
  const vmDiskIds = [vm.value?.bootDiskId, ...(vm.value?.additionalDiskIds || [])].filter(Boolean) as string[]
  if (!vmDiskIds.length) return
  const next: Record<string, DiskUsage> = {}
  await Promise.all(vmDiskIds.map(async (id) => {
    try {
      const { data } = await api.get<DiskUsage>(deviceDiskUsagePath(device, id))
      next[id] = data
    } catch { /* ignore per-disk usage failures */ }
  }))
  if (!stillThisDevice()) return
  memberDiskUsages.value = next
  memberInventoryHostId = host
}

async function fetchDisks() {
  if (isMemberDetail.value) {
    await fetchMemberInventory()
    return
  }
  await diskStore.fetchAll()
  const vmDiskIds = [vm.value?.bootDiskId, ...(vm.value?.additionalDiskIds || [])].filter(Boolean) as string[]
  if (vmDiskIds.length) await diskStore.fetchUsages(vmDiskIds)
}

async function fetchNetworks() {
  if (isMemberDetail.value) {
    await fetchMemberInventory()
    return
  }
  await networkStore.fetchAll()
}

async function fetchBridges() {
  try {
    const { data } = await api.get('/system/bridges')
    bridges.value = data
  } catch {}
}

/** macOS only: socket_vmnet daemon must be active before start. Linux uses host bridges. */
const bridgeNotReady = computed(() => {
  if (isMemberDetail.value) return false
  if (!managedBridge.available) return false
  if (!bridged.available) return false
  if (!currentNetwork.value || currentNetwork.value.mode !== 'bridged' || !currentNetwork.value.bridge) return false
  const info = bridges.value.find(b => b.interface === currentNetwork.value!.bridge)
  return !info || info.status !== 'active'
})

const bridgeStatus = computed(() => {
  if (!currentNetwork.value?.bridge) return null
  return bridges.value.find(b => b.interface === currentNetwork.value!.bridge)?.status || 'not_configured'
})

async function setupBridgeFromDetail() {
  if (isMemberDetail.value || !currentNetwork.value?.bridge) return
  bridgeLoading.value = currentNetwork.value.bridge
  try {
    await api.post('/system/bridges', { interface: currentNetwork.value.bridge })
    toast.success(`Bridge installed for ${currentNetwork.value.bridge}`)
    await fetchBridges()
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    bridgeLoading.value = null
  }
}

async function fetchImages() {
  if (isMemberDetail.value) {
    const device = memberDevice.value
    if (!device || !canFetchDeviceWorkloads(device)) return
    try {
      const { data } = await api.get<Image[]>(devicePath(device, '/images'))
      memberImages.value = Array.isArray(data) ? data : []
    } catch { /* keep last-known */ }
    return
  }
  const { data } = await api.get('/images')
  allImages.value = data
}

const isoImages = computed(() => {
  const ids = vm.value?.isoIds ?? (vm.value?.isoId ? [vm.value.isoId] : [])
  return ids.map(id => detailImages.value.find(i => i.id === id) || { id, name: id.slice(0, 8) + '...', arch: 'arm64' } as any)
})

const availableIsos = computed(() =>
  detailImages.value.filter(i => i.imageType === 'iso' && i.status === 'ready' && !isoImages.value.some(iso => iso.id === i.id))
)

const showIsoAttach = ref(false)
const attachIsoId = ref('')

async function doAttachISO() {
  if (!attachIsoId.value) return
  await action('attach ISO', () => store.attachISO(vmId.value, attachIsoId.value))
  showIsoAttach.value = false
  attachIsoId.value = ''
  fetchImages()
}

function guestInfoDevice() {
  if (isMemberDetail.value) return memberDevice.value
  return devicesStore.selfDevice ?? { hostId: hostId.value || 'self', role: 'self', reachability: 'ok' }
}

async function fetchGuestInfo() {
  const requestVersion = detailLoadVersion
  const requestVmId = vmId.value
  const requestHostId = hostId.value
  const stillCurrent = () =>
    requestVersion === detailLoadVersion
    && requestVmId === vmId.value
    && requestHostId === hostId.value
  const path = guestInfoFetchPath(guestInfoDevice(), requestVmId, vm.value?.state)
  if (!path) {
    guestInfo.value = null
    guestInfoLoaded.value = false
    return
  }
  try {
    const { data } = await api.get(path)
    if (!stillCurrent()) return
    guestInfo.value = data
    guestInfoLoaded.value = true
  } catch {
    if (!stillCurrent()) return
    guestInfo.value = null
    guestInfoLoaded.value = false
  }
}

const memberOsLabel = computed(() => guestOsLabel(
  guestInfo.value,
  vm.value?.vmType ?? 'linux',
  memberReachable.value && vm.value?.state === 'running',
))

const showGuestAgentInstall = computed(() => shouldShowGuestAgentInstall({
  running: vm.value?.state === 'running',
  guestAvailable: guestInfo.value?.available,
  guestInfoLoaded: guestInfoLoaded.value,
  memberUnreachable: isMemberDetail.value && !memberReachable.value,
}))

const guestAgentOpenId = computed(() => guestAgentInstallOpenId({
  vmType: vm.value?.vmType,
  imageName: isoImages.value.map((iso) => iso.name).join(' '),
  osId: guestInfo.value?.osId,
  osName: guestInfo.value?.osName,
}))

const guestListeningPortRows = computed(() => {
  const guest = guestInfo.value
  if (!guest?.listeningPorts) return []
  const ips = guest.ipAddresses ?? []
  const forwards = vm.value?.portForwards ?? []
  const occupied = claimedNatTcpHostPorts(store.vms, allNetworks.value)
  const seenGuest = new Set<number>()
  return guest.listeningPorts.filter(isPublishedGuestPort).map((item) => {
    let publish = suggestPublishNatHostfwd(item, {
      isMember: isMemberDetail.value,
      networkMode: vm.value?.networkId && !currentNetwork.value
        ? 'unresolved'
        : (currentNetwork.value?.mode ?? null),
      portForwards: forwards,
      occupiedHostPorts: occupied,
    })
    if (publish) {
      if (seenGuest.has(item.port)) publish = null
      else seenGuest.add(item.port)
    }
    return {
      key: `${item.proto}-${item.address}-${item.port}`,
      port: item.port,
      address: item.address,
      label: item.label,
      access: guestListeningPortAccessLabel(item),
      href: guestListeningPortHref(item, ips, {
        isMember: isMemberDetail.value,
        guestIpsReachable: currentNetwork.value?.mode === 'bridged',
        portForwards: forwards,
      }),
      publish,
    }
  })
})

async function refreshWorkload() {
  if (isMemberDetail.value) {
    const device = memberDevice.value
    if (!device || !canFetchDeviceWorkloads(device)) return
    await homeWorkloads.refreshOne(device, vmId.value)
    return
  }
  await store.fetchOne(vmId.value)
}

async function startWorkload() {
  if (isMemberDetail.value) {
    const device = memberDevice.value
    if (!device || !canFetchDeviceWorkloads(device)) return
    await homeWorkloads.start(device, vmId.value)
    guestInfo.value = null
    guestInfoLoaded.value = false
    await fetchGuestInfo()
    return
  }
  await store.start(vmId.value)
}

async function sessionAction(kind: 'resume' | 'reset' | 'burn') {
  if (isMemberDetail.value) {
    const device = memberDevice.value
    if (!device || !canFetchDeviceWorkloads(device)) return
    if (kind === 'burn') {
      await homeWorkloads.burnSession(device, vmId.value)
      router.push('/vms')
      return
    }
    if (kind === 'resume') await homeWorkloads.resumeSession(device, vmId.value)
    else await homeWorkloads.resetSession(device, vmId.value)
    guestInfo.value = null
    guestInfoLoaded.value = false
    await fetchGuestInfo()
    return
  }
  if (kind === 'burn') {
    await store.burnSession(vmId.value)
    router.push('/vms')
    return
  }
  if (kind === 'resume') await store.resumeSession(vmId.value)
  else await store.resetSession(vmId.value)
}

async function restartWorkload() {
  if (isMemberDetail.value) {
    const device = memberDevice.value
    if (!device || !canFetchDeviceWorkloads(device)) return
    await homeWorkloads.restart(device, vmId.value)
    guestInfo.value = null
    guestInfoLoaded.value = false
    await fetchGuestInfo()
    return
  }
  await store.restart(vmId.value)
}

async function stopWorkload(method: 'acpi' | 'force') {
  if (isMemberDetail.value) {
    const device = memberDevice.value
    if (!device || !canFetchDeviceWorkloads(device)) return
    await homeWorkloads.stop(device, vmId.value, { method })
    return
  }
  await store.stop(vmId.value, { method })
}

async function patchWorkload(body: Parameters<typeof store.update>[1]) {
  if (isMemberDetail.value) {
    const device = memberDevice.value
    if (!device || !canFetchDeviceWorkloads(device)) {
      throw new Error('This Device did not answer')
    }
    await homeWorkloads.update(device, vmId.value, body)
    return
  }
  await store.update(vmId.value, body)
}



function usbDeviceKey(dev: { deviceId?: string | null; vendorId: string; productId: string; serialNumber?: string | null; id?: string }) {
  if ('id' in dev && dev.id) return dev.id
  return dev.deviceId
    || (dev.serialNumber ? `${dev.vendorId}:${dev.productId}:${dev.serialNumber}` : `${dev.vendorId}:${dev.productId}`)
}

async function fetchUSBDevices() {
  if (isMemberDetail.value) {
    const path = usbInventoryFetchPath(memberDevice.value)
    if (!path) { hostUSBDevices.value = []; return }
    try {
      const { data } = await api.get<HostUSBDevice[]>(path)
      hostUSBDevices.value = Array.isArray(data) ? data : []
    } catch { hostUSBDevices.value = [] }
    return
  }
  try {
    const { data } = await api.get('/system/usb-devices')
    hostUSBDevices.value = data
  } catch { hostUSBDevices.value = [] }
}

async function usbAttach(dev: HostUSBDevice) {
  usbLoading.value = true
  try {
    if (isMemberDetail.value) {
      const device = memberDevice.value
      if (!device || !canFetchDeviceWorkloads(device)) return
      await homeWorkloads.attachUSB(device, vmId.value, usbDeviceKey(dev))
    } else {
      await store.attachUSB(vmId.value, usbDeviceKey(dev))
      await store.fetchOne(vmId.value)
    }
    await fetchUSBDevices()
    showAttachUSB.value = false
    const label = dev.productName || dev.name
    if (vm.value?.state === 'running') {
      toast.show(`USB device "${label}" added — restart the VM to apply.`, { type: 'info' })
    } else {
      toast.success(`USB device "${label}" attached`)
    }
  } catch (e: any) { toast.error(apiErrorMessage(e)) }
  finally { usbLoading.value = false }
}

async function usbDetach(dev: USBPassthroughDevice) {
  usbLoading.value = true
  try {
    if (isMemberDetail.value) {
      const device = memberDevice.value
      if (!device || !canFetchDeviceWorkloads(device)) return
      await homeWorkloads.detachUSB(device, vmId.value, usbDeviceKey(dev))
    } else {
      await store.detachUSB(vmId.value, usbDeviceKey(dev))
      await store.fetchOne(vmId.value)
    }
    await fetchUSBDevices()
    if (vm.value?.state === 'running') {
      toast.show('USB device removed — restart the VM to apply.', { type: 'info' })
    } else {
      toast.success(`USB device detached`)
    }
  } catch (e: any) { toast.error(apiErrorMessage(e)) }
  finally { usbLoading.value = false }
}

async function fetchGPUDevices() {
  if (isMemberDetail.value) {
    const path = gpuInventoryFetchPath(memberDevice.value)
    if (!path) { hostGPUDevices.value = []; return }
    try {
      const { data } = await api.get<HostGPUDevice[]>(path)
      hostGPUDevices.value = Array.isArray(data) ? data : []
    } catch { hostGPUDevices.value = [] }
    return
  }
  try {
    const { data } = await api.get('/system/gpu-devices')
    hostGPUDevices.value = data
  } catch { hostGPUDevices.value = [] }
}

async function gpuAttach(dev: HostGPUDevice) {
  gpuLoading.value = true
  try {
    if (isMemberDetail.value) {
      const device = memberDevice.value
      if (!device || !canFetchDeviceWorkloads(device)) return
      await homeWorkloads.attachGPU(device, vmId.value, dev.pciAddress)
    } else {
      await store.attachGPU(vmId.value, dev.pciAddress)
      await store.fetchOne(vmId.value)
    }
    await fetchGPUDevices()
    showAttachGPU.value = false
    const label = dev.name || dev.pciAddress
    if (vm.value?.state === 'running') {
      toast.show(`GPU "${label}" added — restart the VM to apply.`, { type: 'info' })
    } else {
      toast.success(`GPU "${label}" attached. Guest Ollama is ${GUEST_OLLAMA_PATH}.`)
    }
  } catch (e: any) { toast.error(apiErrorMessage(e)) }
  finally { gpuLoading.value = false }
}

async function gpuDetach(dev: GPUPassthroughDevice) {
  gpuLoading.value = true
  try {
    if (isMemberDetail.value) {
      const device = memberDevice.value
      if (!device || !canFetchDeviceWorkloads(device)) return
      await homeWorkloads.detachGPU(device, vmId.value, dev.pciAddress)
    } else {
      await store.detachGPU(vmId.value, dev.pciAddress)
      await store.fetchOne(vmId.value)
    }
    await fetchGPUDevices()
    if (vm.value?.state === 'running') {
      toast.show('GPU removed — restart the VM to apply.', { type: 'info' })
    } else {
      toast.success('GPU detached')
    }
  } catch (e: any) { toast.error(apiErrorMessage(e)) }
  finally { gpuLoading.value = false }
}

let pollInterval: number | undefined
const stateSSE = useTicketedEventSource()
let detailLoadVersion = 0

function stopRealtimeSync() {
  if (pollInterval) {
    clearInterval(pollInterval)
    pollInterval = undefined
  }
  stateSSE.stop()
}

function connectStateSSE() {
  stateSSE.start({
    vmID: () => vmId.value,
    url: (ticket) => `/api/vms/${vmId.value}/state?ticket=${ticket}`,
    reconnect: true,
    initialDelayMs: 5000,
    maxDelayMs: 30_000,
    onMessage: (e) => {
      try {
        const event = JSON.parse(e.data) as { id: string; state: string; error?: string | null }
        const v = store.vms.find(v => v.id === event.id)
        if (v) applyVMStateEvent(v, event)
        fetchGuestInfo()
      } catch { /* ignore */ }
    },
  })
}

async function pollMemberDetail(loadVersion: number) {
  if (loadVersion !== detailLoadVersion) return
  try {
    await devicesStore.fetchHealth()
  } catch { /* keep last health */ }
  if (loadVersion !== detailLoadVersion) return
  const current = devicesStore.deviceByHostId(hostId.value)
  if (!current || isSelfDevice(current) || !canFetchDeviceWorkloads(current)) return
  try {
    await homeWorkloads.refreshOne(current, vmId.value)
    if (loadVersion !== detailLoadVersion) return
    memberLoadError.value = null
    await fetchGuestInfo()
    if (loadVersion !== detailLoadVersion) return
    if (memberInventoryHostId !== current.hostId) {
      await fetchMemberInventory()
    }
  } catch (e: any) {
    if (loadVersion !== detailLoadVersion) return
    memberLoadError.value = apiErrorMessage(e)
    if (!isNotFoundError(e)) return
    homeWorkloads.removeOne(current.hostId, vmId.value)
    stopRealtimeSync()
  }
}

async function loadMemberDetail() {
  const loadVersion = ++detailLoadVersion
  stopRealtimeSync()
  guestInfo.value = null
  memberLoadError.value = null
  memberLoadSettled.value = false
  try {
    await devicesStore.fetchHealth()
    if (loadVersion !== detailLoadVersion) return
    const device = devicesStore.deviceByHostId(hostId.value)
    if (device && isSelfDevice(device)) {
      await loadLocalDetail(loadVersion)
      return
    }
    if (device && canFetchDeviceWorkloads(device)) {
      try {
        await homeWorkloads.refreshOne(device, vmId.value)
        if (loadVersion !== detailLoadVersion) return
        memberLoadError.value = null
        await homeWorkloads.fetchSpec(device, vmId.value).catch(() => {})
        await fetchMemberInventory()
      } catch (e: any) {
        if (isNotFoundError(e)) {
          homeWorkloads.removeOne(device.hostId, vmId.value)
          memberLoadError.value = apiErrorMessage(e)
          return
        }
        memberLoadError.value = apiErrorMessage(e)
      }
      if (loadVersion !== detailLoadVersion) return
      await fetchGuestInfo()
    }
    if (loadVersion !== detailLoadVersion) return
    pollInterval = window.setInterval(() => {
      void pollMemberDetail(loadVersion)
    }, 15000)
  } finally {
    if (loadVersion === detailLoadVersion) memberLoadSettled.value = true
  }
}

async function loadLocalDetail(existingVersion?: number) {
  const loadVersion = existingVersion ?? ++detailLoadVersion
  stopRealtimeSync()
  guestInfo.value = null
  diskUsages.value = {}
  try {
    await Promise.all([
      store.fetchOne(vmId.value),
      store.fetchAll(),
      fetchNetworks(),
      fetchImages(),
      ...(managedBridge.available ? [fetchBridges()] : []),
    ])
    if (loadVersion !== detailLoadVersion) return

    await fetchDisks()
    if (loadVersion !== detailLoadVersion) return

    await fetchGuestInfo()
    if (loadVersion !== detailLoadVersion) return

    connectStateSSE()
    pollInterval = window.setInterval(() => {
      store.fetchOne(vmId.value).then(fetchGuestInfo).catch(() => {})
      if (managedBridge.available) fetchBridges()
    }, 15000)
  } catch (e: any) {
    if (loadVersion === detailLoadVersion) {
      toast.error(apiErrorMessage(e))
    }
  }
}

async function loadVMDetail() {
  if (hostId.value) {
    await loadMemberDetail()
    return
  }
  memberLoadSettled.value = true
  await loadLocalDetail()
}

onMounted(() => {
  void loadVMDetail()
})

watch([vmId, hostId], ([newId, newHost], [oldId, oldHost]) => {
  if (newId !== oldId || newHost !== oldHost) {
    if (newHost !== oldHost) resetMemberInventory()
    void loadVMDetail()
  }
})

onUnmounted(() => {
  detailLoadVersion++
  stopRealtimeSync()
})

const toast = useToastStore()

async function action(name: string, fn: () => Promise<void>) {
  actionLoading.value = name
  try {
    await fn()
  } catch (e: any) {
    const reason = apiErrorMessage(e)
    const code = e.response?.data?.code
    if (code === 'bridge_not_ready') {
      toast.error(reason + ' Go to Network settings to set it up.')
      fetchBridges()
    } else {
      toast.error(reason)
    }
  }
  finally { actionLoading.value = '' }
}

const stopConfirm = ref<{ method: 'acpi' | 'force' } | null>(null)
const stopLoading = ref(false)

function requestStop(method: 'acpi' | 'force') {
  if (isMemberDetail.value && !memberReachable.value) return
  stopConfirm.value = { method }
}

async function confirmStop() {
  if (!stopConfirm.value) return
  const method = stopConfirm.value.method
  stopConfirm.value = null
  stopLoading.value = true
  actionLoading.value = method === 'force' ? 'force-stop' : 'stop'
  try {
    await stopWorkload(method)
    await refreshWorkload()
    guestInfo.value = null
    guestInfoLoaded.value = false
    await fetchGuestInfo()
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    stopLoading.value = false
    actionLoading.value = ''
  }
}

const showDeleteDialog = ref(false)
const keepDisk = ref(false)
const showFolderPicker = ref(false)
const deletingVM = ref(false)
const detaching = ref(false)
const removingShare = ref(false)

let deletePollerStop: (() => void) | null = null

async function deleteVM() {
  deletingVM.value = true
  try {
    const taskID = await store.remove(vmId.value, keepDisk.value)
    if (taskID) {
      // Background deletion — poll until done then navigate
      const { useTaskPoller } = await import('../composables/useTaskPoller')
      const { poll, stop } = useTaskPoller()
      deletePollerStop = stop
      await poll(taskID, {
        onComplete: () => { router.push('/vms') },
        onFailed: async (event) => {
          toast.error(event.error || 'VM deletion failed')
          await store.fetchOne(vmId.value).catch(() => {})
        },
      })
    } else {
      router.push('/vms')
    }
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    deletingVM.value = false
    showDeleteDialog.value = false
    deletePollerStop = null
  }
}

onUnmounted(() => {
  deletePollerStop?.()
})

async function addSharedPath(path: string) {
  const current = vm.value?.sharedPaths || []
  if (current.includes(path)) return
  await store.update(vmId.value, { sharedPaths: [...current, path] } as any)
}

function removeSharedPath(path: string) {
  confirmRemoveShare.value = path
}

async function doRemoveSharedPath() {
  if (!confirmRemoveShare.value) return
  const path = confirmRemoveShare.value
  removingShare.value = true
  try {
    const current = vm.value?.sharedPaths || []
    await store.update(vmId.value, { sharedPaths: current.filter(p => p !== path) } as any)
  } finally {
    removingShare.value = false
    confirmRemoveShare.value = null
  }
}

function openEditModal() {
  if (isMemberDetail.value && editCpuMax.value == null) {
    toast.info('Waiting for Device capabilities')
    return
  }
  const current = vm.value?.cpuCount || 1
  const max = editCpuMax.value
  const cpu = max ? Math.min(Math.max(1, current), max) : Math.max(1, current)
  editDraft.value = {
    description: vm.value?.description || '',
    cpuCount: cpu,
    memoryMB: vm.value?.memoryMB || 512,
    bootOrder: vm.value?.bootOrder || 'cd',
    networkId: vm.value?.networkId || defaultNetwork.value?.id || '',
  }
  showEditModal.value = true
}

async function saveEdit() {
  if (isMemberDetail.value && editCpuMax.value == null) {
    toast.error('Device capabilities not loaded')
    return
  }
  editSaving.value = true
  try {
    const rawCpu = Math.max(1, Math.trunc(editDraft.value.cpuCount))
    const max = editCpuMax.value
    const cpu = max ? Math.min(rawCpu, max) : rawCpu
    await patchWorkload({
      description: editDraft.value.description,
      cpuCount: cpu,
      memoryMB: editDraft.value.memoryMB,
      bootOrder: editDraft.value.bootOrder,
      networkId: editDraft.value.networkId || vm.value?.networkId || null,
    } as any)
    showEditModal.value = false
    await refreshWorkload()
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    editSaving.value = false
  }
}

async function attachDisk(diskId: string) {
  attachLoading.value = true
  try {
    const current = vm.value?.additionalDiskIds || []
    await patchWorkload({ additionalDiskIds: [...current, diskId] } as any)
    showAttachDisk.value = false
    await refreshWorkload()
    if (isMemberDetail.value) await fetchMemberInventory()
    else await fetchDisks()
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    attachLoading.value = false
  }
}

const confirmDetachDisk = ref<string | null>(null)
const confirmRemoveShare = ref<string | null>(null)

function detachDisk(diskId: string) {
  confirmDetachDisk.value = diskId
}

async function doDetachDisk() {
  if (!confirmDetachDisk.value) return
  const diskId = confirmDetachDisk.value
  detaching.value = true
  try {
    const current = vm.value?.additionalDiskIds || []
    await patchWorkload({ additionalDiskIds: current.filter(d => d !== diskId) } as any)
    await refreshWorkload()
    if (isMemberDetail.value) await fetchMemberInventory()
    else await fetchDisks()
  } catch (e: any) {
    toast.error(apiErrorMessage(e))
  } finally {
    detaching.value = false
    confirmDetachDisk.value = null
  }
}

const defaultNetwork = computed(() => detailNetworks.value.find(n => n.isDefault))

const currentNetwork = computed(() => {
  if (isMemberDetail.value) {
    return memberNetworkForDetail(vm.value?.networkId, memberNetworks.value)
  }
  return localNetworkForDetail(false, vm.value?.networkId, allNetworks.value)
})

const backend = computed(() => (vm.value ? vmBackend(vm.value) : null))

</script>

<template>
  <div v-if="!vm" class="empty">
    <template v-if="isMemberDetail && memberLoadSettled">
      <div class="page-header">
        <div style="display:flex;align-items:center;gap:10px">
          <button class="back-icon" @click="router.push('/vms')" title="Back to VMs">
            <AppIcon name="chevron-left" :size="18" />
          </button>
          <h1>{{ vmId }}</h1>
        </div>
      </div>
      <p v-if="memberLoadError" class="list-error">{{ memberLoadError }}</p>
      <p v-else-if="!memberReachable">
        This {{ DEVICE_LABEL.toLowerCase() }} did not answer. Live state unavailable.
      </p>
      <p v-else>Workload not found on this {{ DEVICE_LABEL.toLowerCase() }}.</p>
    </template>
    <p v-else>Loading...</p>
  </div>
  <div v-else>
    <div class="page-header">
      <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
        <button class="back-icon" @click="router.push('/vms')" title="Back to VMs">
          <AppIcon name="chevron-left" :size="18" />
        </button>
        <h1>{{ vm.name }}</h1>
        <span class="badge badge-gray" :title="grantCopy">{{ grantCopy }}</span>
        <WorkloadDeviceChip
          v-if="isMemberDetail && memberDevice"
          :label="devicesStore.deviceLabel(memberDevice)"
          :reachable="memberReachable"
        />
      </div>
      <div style="display: flex; gap: 8px; align-items: center">
        <span
          class="status-pill"
          :class="healthPillClass(vmHealth(vm))"
          :title="vm.status?.healthError || undefined"
        >{{ healthLabel(vmHealth(vm)) }}</span>
        <AppButton v-if="vm.state === 'stopped' || vm.state === 'error'" variant="primary"
          :disabled="controlDisabled" @click="action('start', () => startWorkload())">Start</AppButton>
        <StopButtonGroup v-if="vm.state === 'running' || vm.state === 'stopping'" :loading="controlDisabled || stopLoading" @stop="requestStop($event)" />
        <AppButton
          v-if="showMemberConnect && (vm.state === 'running' || vm.state === 'stopping')"
          title="Open VNC in a new resizable window"
          :disabled="vm.state !== 'running'"
          @click="openVncWindow"
        >VNC</AppButton>
        <AppButton v-if="vm.state === 'running'"
          :disabled="controlDisabled" @click="action('restart', () => restartWorkload())">Restart</AppButton>
        <AppButton v-if="!isMemberDetail && (vm.state === 'stopped' || vm.state === 'error')" variant="danger" :disabled="!!actionLoading" @click="showDeleteDialog = true; keepDisk = false">Delete</AppButton>
      </div>
    </div>

    <div v-if="!isMemberDetail" class="tabs">
      <div class="tab" :class="{ active: tab === 'overview' }" @click="tab = 'overview'">Overview</div>
      <div v-if="showAgentChat" class="tab" :class="{ active: tab === 'chat' }" @click="tab = 'chat'">Chat</div>
      <div class="tab" :class="{ active: tab === 'console' }" @click="tab = 'console'">{{ consoleLabel }}</div>
      <div class="tab" :class="{ active: tab === 'vnc' }" @click="tab = 'vnc'">VNC</div>
      <div v-if="vm.state === 'running'" class="tab" :class="{ active: tab === 'metrics' }" @click="tab = 'metrics'">Metrics</div>
    </div>
    <div v-else class="tabs">
      <div class="tab" :class="{ active: tab === 'overview' }" @click="tab = 'overview'">Overview</div>
      <div v-if="showAgentChat" class="tab" :class="{ active: tab === 'chat' }" @click="tab = 'chat'">Chat</div>
      <div v-if="showMemberConnect" class="tab" :class="{ active: tab === 'console' }" @click="tab = 'console'">{{ consoleLabel }}</div>
      <div v-if="showMemberConnect" class="tab" :class="{ active: tab === 'vnc' }" @click="tab = 'vnc'">VNC</div>
      <div v-if="vm.state === 'running'" class="tab" :class="{ active: tab === 'metrics' }" @click="tab = 'metrics'">Metrics</div>
      <div class="tab" :class="{ active: tab === 'logs' }" @click="tab = 'logs'">Logs</div>
    </div>

    <div v-if="isMemberDetail && !memberReachable" class="pending-banner">
      This {{ DEVICE_LABEL.toLowerCase() }} did not answer. Showing last-known data, not live state.
    </div>
    <p v-if="isMemberDetail && memberLoadError" class="list-error">{{ memberLoadError }}</p>

    <div v-if="codingAgent && session?.warning" class="pending-banner">
      {{ sessionWarningCopy(session.remainingSeconds) }}
    </div>

    <div v-if="codingAgent && sessionReceipt" class="pending-banner" :class="{ 'session-nopush': sessionReceipt.loud }">
      Stopped at {{ sessionReceipt.stoppedAt }}.
      <strong v-if="sessionReceipt.loud">{{ SESSION_NO_PUSH }}</strong>
      <span v-else>Last git push {{ sessionReceipt.git }}.</span>
    </div>

    <div v-if="vm.pendingChanges" class="pending-banner">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
      </svg>
      Configuration changed. Restart the VM to apply new settings.
    </div>

    <div v-if="backend?.emulated && backend.warning" class="emu-banner">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
      </svg>
      {{ backend.warning }}
    </div>

    <div v-if="!isMemberDetail && bridgeNotReady && (vm.state === 'stopped' || vm.state === 'error')" class="bridge-banner">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
      </svg>
      <span v-if="bridgeStatus === 'installed'">Bridge daemon is not running for <strong>{{ currentNetwork?.bridge }}</strong>. The VM cannot start until the daemon is active.</span>
      <span v-else>Bridge is not configured for <strong>{{ currentNetwork?.bridge }}</strong>. The VM cannot start until the bridge is set up.</span>
      <AppButton size="sm" style="margin-left:auto;flex-shrink:0" :loading="!!bridgeLoading" loading-text="Setting up..." @click="setupBridgeFromDetail">Setup Bridge</AppButton>
    </div>

    <div v-if="tab === 'overview'">
      <div v-if="codingAgent && session" class="card" style="margin-bottom:16px">
        <div class="detail-row">
          <span class="detail-label">Session TTL</span>
          <span>{{ session.expiryAction === 'stop' ? 'Stop (keep disk)' : session.expiryAction }}</span>
        </div>
        <div v-if="session.expiresAt" class="detail-row">
          <span class="detail-label">Expires</span>
          <span class="mono">{{ session.expiresAt }}</span>
        </div>
        <div style="display:flex;gap:8px;flex-wrap:wrap;margin-top:12px">
          <AppButton
            v-if="vm.state === 'stopped' || vm.state === 'error'"
            variant="primary"
            :disabled="controlDisabled"
            @click="action('resume', () => sessionAction('resume'))"
          >Resume</AppButton>
          <AppButton :disabled="controlDisabled" @click="showResetDialog = true">Reset to Library image</AppButton>
          <AppButton variant="danger" :disabled="controlDisabled" @click="showBurnDialog = true">Burn</AppButton>
        </div>
      </div>
      <div class="card">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px">
          <div></div>
          <AppButton size="sm" :disabled="isMemberDetail && (!memberReachable || !editCpuMax)" @click="openEditModal">Edit Settings</AppButton>
        </div>
        <div class="detail-grid">
          <div class="detail-row">
            <span class="detail-label">Type</span>
            <span><span class="badge badge-gray">{{ vm.vmType.startsWith('windows') ? 'Windows' : 'Linux' }}</span></span>
          </div>
          <div v-if="backend" class="detail-row">
            <span class="detail-label">Architecture</span>
            <span class="mono">{{ architectureLabel(backend.guestArch) }}</span>
          </div>
          <div v-if="backend" class="detail-row">
            <span class="detail-label">Accelerator</span>
            <span style="display:flex;align-items:center;gap:6px">
              <span class="mono">{{ acceleratorLabel(backend.accelerator) }}</span>
              <span v-if="backend.emulated" class="badge badge-amber">emulated</span>
              <span v-else class="badge badge-green">hardware</span>
            </span>
          </div>
          <div v-if="backend" class="detail-row">
            <span class="detail-label">QEMU</span>
            <span class="mono" style="color:var(--text-secondary)">{{ backend.qemuBinary }}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">CPU</span>
            <span>{{ vm.cpuCount }} cores</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Memory</span>
            <span>{{ vm.memoryMB }} MB</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Description</span>
            <span style="color:var(--text-secondary)">{{ vm.description || '-' }}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Boot Order</span>
            <span class="mono">{{ vm.bootOrder || 'cd' }}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Resolution</span>
            <span class="mono">{{ vm.displayResolution || '1280x800' }}</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Network</span>
            <span style="display:flex;align-items:center;gap:6px">
              <template v-if="currentNetwork">
                <span style="color:var(--text-secondary)">{{ currentNetwork.name }}</span>
                <span class="badge badge-gray">{{ currentNetwork.mode }}</span>
                <template v-if="!isMemberDetail && currentNetwork.mode === 'bridged' && currentNetwork.bridge">
                  <span class="mono" style="color:var(--text-dim);font-size:12px">{{ currentNetwork.bridge }}</span>
                  <span v-if="bridgeStatus === 'active'" class="badge badge-green">active</span>
                  <span v-else-if="bridgeStatus === 'installed'" class="badge badge-accent">installed</span>
                  <span v-else class="badge badge-gray">no bridge</span>
                </template>
              </template>
              <span v-else-if="isMemberDetail" :class="vm.networkId ? 'mono' : ''" :style="vm.networkId ? undefined : 'color:var(--text-dim)'">
                {{ memberNetworkCaption(vm.networkId) }}
              </span>
              <span v-else style="color:var(--text-dim)">Default NAT</span>
            </span>
          </div>
          <div v-if="!currentNetwork || currentNetwork.mode === 'nat'" class="detail-row">
            <span class="detail-label">Port Forwards</span>
            <span class="detail-editable">
              <span v-if="vm.portForwards && vm.portForwards.length > 0" style="display:flex;flex-wrap:wrap;gap:4px">
                <span v-for="(pf, i) in vm.portForwards" :key="i" class="badge badge-gray" style="font-variant-numeric:tabular-nums">
                  {{ pf.protocol }}:{{ pf.hostPort }}&rarr;{{ pf.guestPort }}
                </span>
              </span>
              <span v-else style="color:var(--text-dim)">None</span>
              <AppButton size="sm" :disabled="isMemberDetail && !memberReachable" @click="openPortForwardEditor()">Edit</AppButton>
            </span>
          </div>
          <div v-if="!isMemberDetail && currentNetwork?.mode === 'bridged' && (vm.portForwards?.length ?? 0) > 0" class="detail-row">
            <span class="detail-label">Services</span>
            <span style="display:flex;flex-wrap:wrap;gap:4px">
              <template v-if="guestInfo?.ipAddresses?.length">
                <a v-for="(pf, i) in vm.portForwards!.filter(p => p.protocol === 'tcp')" :key="i"
                   :href="(pf.guestPort === 443 || pf.guestPort === 9443 ? 'https://' : 'http://') + guestInfo.ipAddresses[0] + (pf.guestPort === 80 || pf.guestPort === 443 ? '' : ':' + pf.guestPort)"
                   target="_blank" class="badge badge-accent" style="text-decoration:none;font-variant-numeric:tabular-nums;cursor:pointer">
                  {{ guestInfo.ipAddresses[0] }}{{ pf.guestPort === 80 || pf.guestPort === 443 ? '' : ':' + pf.guestPort }}
                </a>
              </template>
              <template v-else>
                <span v-for="(pf, i) in vm.portForwards!.filter(p => p.protocol === 'tcp')" :key="i" class="badge badge-gray" style="font-variant-numeric:tabular-nums">
                  port {{ pf.guestPort }}
                </span>
                <span style="color:var(--text-dim);font-size:12px">{{ showGuestAgentInstall ? 'Install the guest agent below' : 'waiting for guest agent...' }}</span>
              </template>
            </span>
          </div>
          <div class="detail-row">
            <span class="detail-label">ISOs</span>
            <span style="display:flex;flex-direction:column;gap:6px;flex:1">
              <div v-for="iso in isoImages" :key="iso.id" style="display:flex;align-items:center;justify-content:space-between">
                <span style="display:flex;align-items:center;gap:8px">
                  <a href="#" @click.prevent="router.push('/images')" style="color:var(--accent);text-decoration:none;font-size:13px">
                    {{ iso.name }}
                  </a>
                  <span v-if="!isMemberDetail" class="badge badge-gray">{{ iso.arch }}</span>
                </span>
                <AppButton v-if="!isMemberDetail" size="sm" :disabled="!!actionLoading"
                  @click="action('detach ISO', () => store.detachISO(vmId, iso.id))">Detach</AppButton>
              </div>
              <div v-if="isoImages.length === 0" style="font-size:12px;color:var(--text-dim)">No ISOs attached</div>
              <div v-if="!isMemberDetail && showIsoAttach" style="display:flex;gap:6px;align-items:end;margin-top:4px">
                <AppSelect v-model="attachIsoId" size="sm" style="flex:1">
                  <option value="" disabled>Select ISO...</option>
                  <option v-for="img in availableIsos" :key="img.id" :value="img.id">{{ img.name }}</option>
                </AppSelect>
                <AppButton variant="primary" size="sm" :disabled="!attachIsoId || !!actionLoading" @click="doAttachISO">Attach</AppButton>
                <AppButton size="sm" @click="showIsoAttach = false; attachIsoId = ''">Cancel</AppButton>
              </div>
              <AppButton v-else-if="!isMemberDetail" size="sm" icon="plus" style="align-self:flex-start;margin-top:2px" @click="showIsoAttach = true; fetchImages()">Attach ISO</AppButton>
            </span>
          </div>
          <div v-if="vm.macAddress" class="detail-row">
            <span class="detail-label">MAC Address</span>
            <span class="mono" style="color:var(--text-secondary)">{{ vm.macAddress }}</span>
          </div>
          <div v-if="isMemberDetail" class="detail-row">
            <span class="detail-label">OS</span>
            <span>{{ memberOsLabel }}</span>
          </div>
          <div v-if="vm.state === 'running' && guestInfo?.available && guestInfo?.ipAddresses?.length" class="detail-row">
            <span class="detail-label">IP Address</span>
            <span style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
              <span v-for="ip in guestInfo.ipAddresses" :key="ip" class="badge badge-accent" style="font-variant-numeric:tabular-nums">{{ ip }}</span>
            </span>
          </div>
          <div v-else-if="isMemberDetail" class="detail-row">
            <span class="detail-label">IP Address</span>
            <span style="color:var(--text-dim)">—</span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Created</span>
            <span style="color:var(--text-secondary)">{{ new Date(vm.createdAt).toLocaleString() }}</span>
          </div>
        </div>
      </div>

      <!-- Guest agent install (PAS-215) -->
      <div v-if="showGuestAgentInstall" style="margin-top:20px">
        <h2 style="font-size:16px;font-weight:700;margin-bottom:12px">Guest Agent</h2>
        <div class="card">
          <p style="color:var(--text-secondary);font-size:13px;margin:0 0 14px;line-height:1.5">
            Install the guest agent inside this Workload to show IP and OS, and to shut down cleanly.
          </p>
          <GuestCommandAccordion
            :groups="guestAgentInstallCommands"
            :initial-open="guestAgentOpenId"
          />
          <!-- PAS-214: clipboard is spice-vdagent / Spice guest tools, not qemu-guest-agent -->
          <p style="color:var(--text-dim);font-size:11px;margin:12px 0 0;line-height:1.5">
            Desktop clipboard still needs <code style="background:rgba(255,255,255,0.06);padding:1px 4px;border-radius:2px">spice-vdagent</code>
            (Linux) or Spice guest tools (Windows).
          </p>
        </div>
      </div>

      <!-- Guest Agent Info -->
      <div v-if="vm.state === 'running' && guestInfo?.available" style="margin-top:20px">
        <h2 style="font-size:16px;font-weight:700;margin-bottom:12px">Guest Agent</h2>
        <div class="card">
          <div class="detail-grid">
            <div v-if="guestInfo.hostname" class="detail-row">
              <span class="detail-label">Hostname</span>
              <span class="mono">{{ guestInfo.hostname }}</span>
            </div>
            <div v-if="guestInfo.osName" class="detail-row">
              <span class="detail-label">OS</span>
              <span>{{ guestInfo.osName }}<template v-if="guestInfo.osVersion"> {{ guestInfo.osVersion }}</template></span>
            </div>
            <div v-if="guestInfo.kernelRelease" class="detail-row">
              <span class="detail-label">Kernel</span>
              <span class="mono">{{ guestInfo.kernelRelease }}</span>
            </div>
            <div v-if="guestInfo.machine" class="detail-row">
              <span class="detail-label">Architecture</span>
              <span class="mono">{{ guestInfo.machine }}</span>
            </div>
            <div v-if="guestInfo.ipAddresses?.length" class="detail-row">
              <span class="detail-label">IP Addresses</span>
              <span style="display:flex;gap:6px;flex-wrap:wrap">
                <span v-for="ip in guestInfo.ipAddresses" :key="ip" class="badge badge-accent" style="font-variant-numeric:tabular-nums">{{ ip }}</span>
              </span>
            </div>
            <div v-if="guestInfo.macAddress" class="detail-row">
              <span class="detail-label">MAC Address</span>
              <span class="mono" style="color:var(--text-secondary)">{{ guestInfo.macAddress }}</span>
            </div>
            <div v-if="guestInfo.timezone" class="detail-row">
              <span class="detail-label">Timezone</span>
              <span>{{ guestInfo.timezone }}<template v-if="guestInfo.timezoneOffset != null"> (UTC{{ guestInfo.timezoneOffset >= 0 ? '+' : '' }}{{ guestInfo.timezoneOffset / 3600 }})</template></span>
            </div>
            <div v-if="guestInfo.users?.length" class="detail-row">
              <span class="detail-label">Logged In Users</span>
              <span style="display:flex;gap:6px;flex-wrap:wrap">
                <span v-for="u in guestInfo.users" :key="u.name" class="badge badge-gray">{{ u.name }}</span>
              </span>
            </div>
          </div>

          <div v-if="guestInfo.listeningPorts != null" style="margin-top:16px">
            <h3 style="font-size:13px;font-weight:600;color:var(--text-dim);text-transform:uppercase;letter-spacing:0.04em;margin-bottom:8px">Listening ports</h3>
            <p v-if="guestListeningPortRows.length === 0" style="color:var(--text-dim);font-size:12px;margin:0">None</p>
            <DataTable v-else :columns="[{ key: 'port', label: 'Port' }, { key: 'address', label: 'Address' }, { key: 'label', label: 'Service' }, { key: 'access', label: 'Access' }, { key: 'publish', label: '' }]">
              <tr v-for="row in guestListeningPortRows" :key="row.key">
                <td class="mono" style="font-variant-numeric:tabular-nums">{{ row.port }}</td>
                <td class="mono">{{ row.address }}</td>
                <td><span v-if="row.label" class="badge badge-gray">{{ row.label }}</span><span v-else style="color:var(--text-dim)">—</span></td>
                <td>
                  <span v-if="row.access === 'Internal'" class="badge badge-gray">Internal</span>
                  <a v-else-if="row.href" :href="row.href" target="_blank" class="badge badge-accent" style="text-decoration:none">{{ row.href.replace(/^https?:\/\//, '') }}</a>
                  <span v-else class="mono">{{ row.access }}</span>
                </td>
                <td>
                  <AppButton v-if="row.publish" size="sm" @click="openPortForwardEditor(row.publish)">Publish this port</AppButton>
                </td>
              </tr>
            </DataTable>
          </div>

          <!-- Filesystems sub-table -->
          <div v-if="guestInfo.filesystems?.length" style="margin-top:16px">
            <h3 style="font-size:13px;font-weight:600;color:var(--text-dim);text-transform:uppercase;letter-spacing:0.04em;margin-bottom:8px">Filesystems</h3>
            <DataTable :columns="[{ key: 'mount', label: 'Mount' }, { key: 'type', label: 'Type' }, { key: 'device', label: 'Device' }, { key: 'used', label: 'Used' }, { key: 'total', label: 'Total' }]">
                  <tr v-for="fs in guestInfo.filesystems" :key="fs.mountpoint">
                    <td class="mono">{{ fs.mountpoint }}</td>
                    <td><span class="badge badge-gray">{{ fs.type }}</span></td>
                    <td class="mono">{{ fs.device }}</td>
                    <td class="mono">{{ fs.usedBytes != null ? formatBytes(fs.usedBytes) : '-' }}</td>
                    <td class="mono">{{ fs.totalBytes != null ? formatBytes(fs.totalBytes) : '-' }}</td>
                  </tr>
            </DataTable>
          </div>
        </div>
      </div>

      <!-- Disks Section -->
      <div style="margin-top:20px">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
          <h2 style="font-size:16px;font-weight:700">Disks</h2>
          <AppButton size="sm" icon="plus" :disabled="isMemberDetail && !memberReachable" @click="showAttachDisk = true; fetchDisks()">Attach Disk</AppButton>
        </div>
        <DataTable :columns="[{ key: 'name', label: 'Name' }, { key: 'format', label: 'Format' }, { key: 'provisioned', label: 'Provisioned' }, { key: 'used', label: 'Used' }, { key: 'role', label: 'Role' }, { key: 'actions', label: '' }]">
              <!-- Boot disk -->
              <tr>
                <td style="font-weight:500">
                  <a v-if="!isMemberDetail" href="#" @click.prevent="router.push('/disks')" style="color:var(--accent);text-decoration:none">
                    {{ detailDisks.find(d => d.id === vm!.bootDiskId)?.name || vm!.bootDiskId.slice(0,8) + '...' }}
                  </a>
                  <span v-else>
                    {{ detailDisks.find(d => d.id === vm!.bootDiskId)?.name || vm!.bootDiskId.slice(0,8) + '...' }}
                  </span>
                </td>
                <td><span class="badge badge-gray">qcow2</span></td>
                <td class="mono">{{ detailDisks.find(d => d.id === vm!.bootDiskId) ? formatBytes(detailDisks.find(d => d.id === vm!.bootDiskId)!.sizeBytes) : '-' }}</td>
                <td class="mono">
                  <template v-if="detailDiskUsages[vm!.bootDiskId]">{{ formatBytes(detailDiskUsages[vm!.bootDiskId].actualSizeBytes) }}</template>
                  <span v-else style="color:var(--text-dim)">-</span>
                </td>
                <td><span class="badge badge-accent">Boot</span></td>
                <td></td>
              </tr>
              <!-- Additional disks -->
              <tr v-for="disk in additionalDiskDetails" :key="disk.id">
                <td style="font-weight:500">
                  <a v-if="!isMemberDetail" href="#" @click.prevent="router.push('/disks')" style="color:var(--accent);text-decoration:none">{{ disk.name }}</a>
                  <span v-else>{{ disk.name }}</span>
                </td>
                <td><span class="badge badge-gray">{{ disk.format }}</span></td>
                <td class="mono">{{ formatBytes(disk.sizeBytes) }}</td>
                <td class="mono">
                  <template v-if="detailDiskUsages[disk.id]">{{ formatBytes(detailDiskUsages[disk.id].actualSizeBytes) }}</template>
                  <span v-else style="color:var(--text-dim)">-</span>
                </td>
                <td><span class="badge badge-blue">Extra</span></td>
                <td style="text-align:right">
                  <span v-if="vm?.state === 'running'" style="font-size:12px;color:var(--text-dim)">Stop VM to detach</span>
                  <AppButton v-else size="sm" :disabled="isMemberDetail && !memberReachable" @click="detachDisk(disk.id)">Detach</AppButton>
                </td>
              </tr>
              <tr v-if="!additionalDiskDetails.length">
                <td colspan="6"><EmptyState title="No additional disks attached" /></td>
              </tr>
        </DataTable>
      </div>

      <!-- Shared Folders Section -->
      <div v-if="!isMemberDetail && !agentCage" style="margin-top:20px">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
          <h2 style="font-size:16px;font-weight:700">Shared Folders</h2>
          <AppButton size="sm" icon="plus" @click="showFolderPicker = true">Add Shared Folder</AppButton>
        </div>
        <DataTable :columns="[{ key: 'path', label: 'Host Path' }, { key: 'tag', label: 'Mount Tag' }, { key: 'actions', label: '' }]">
              <tr v-for="(path, i) in (vm.sharedPaths || [])" :key="path">
                <td style="font-weight:500;font-family:var(--font-mono);font-size:12px">{{ path }}</td>
                <td><span class="badge badge-gray">{{ i === 0 ? 'hostshare' : `hostshare${i}` }}</span></td>
                <td style="text-align:right">
                  <AppButton size="sm" variant="danger" @click="removeSharedPath(path)">Remove</AppButton>
                </td>
              </tr>
              <tr v-if="!vm.sharedPaths?.length">
                <td colspan="3">
                  <EmptyState title="No shared folders" subtitle="Mount inside guest: mount -t 9p -o trans=virtio hostshare /mnt/share" />
                </td>
              </tr>
        </DataTable>
      </div>

      <!-- USB Devices Section -->
      <div v-if="!agentCage" style="margin-top:20px">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
          <h2 style="font-size:16px;font-weight:700">USB Devices</h2>
          <AppButton
            size="sm"
            icon="plus"
            :disabled="!usbAvailable || (isMemberDetail && !memberReachable)"
            :title="usbAvailable ? undefined : usbExplanation"
            @click="showAttachUSB = true; fetchUSBDevices()"
          >Attach USB Device</AppButton>
        </div>
        <UnsupportedHint v-if="!usbAvailable" :text="usbExplanation" />
        <DataTable v-else :columns="[{ key: 'device', label: 'Device' }, { key: 'id', label: 'ID' }, { key: 'actions', label: '' }]">
              <tr v-for="dev in (vm.usbDevices || [])" :key="usbDeviceKey(dev)">
                <td>
                  <div style="font-weight:500">{{ dev.label || `${dev.vendorId}:${dev.productId}` }}</div>
                  <div v-if="dev.serialNumber" style="font-size:11px;color:var(--text-dim)">Serial {{ dev.serialNumber }}</div>
                </td>
                <td><span class="badge badge-gray" style="font-family:var(--font-mono);font-size:11px">{{ usbDeviceKey(dev) }}</span></td>
                <td style="text-align:right">
                  <span v-if="vm?.state === 'running'" style="font-size:12px;color:var(--text-dim)">Stop VM to detach</span>
                  <AppButton v-else size="sm" variant="danger" :disabled="usbLoading || (isMemberDetail && !memberReachable)" @click="usbDetach(dev)">Detach</AppButton>
                </td>
              </tr>
              <tr v-if="!vm.usbDevices?.length">
                <td colspan="4"><EmptyState title="No USB devices attached" :subtitle="isMemberDetail ? 'Attach a USB device from that Device.' : 'Click &quot;Attach USB Device&quot; to pass through a USB device from this device.'" /></td>
              </tr>
        </DataTable>
      </div>

      <div style="margin-top:20px">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
          <h2 style="font-size:16px;font-weight:700">GPU passthrough</h2>
          <AppButton
            size="sm"
            icon="plus"
            :disabled="!gpuReady || (isMemberDetail && !memberReachable)"
            :title="gpuReady ? undefined : gpuExplanation"
            @click="showAttachGPU = true; fetchGPUDevices()"
          >Attach GPU</AppButton>
        </div>
        <p style="font-size:13px;color:var(--text-secondary);margin:0 0 8px">
          {{ gpuReady ? 'Attach like USB. Guest Ollama is ' + GUEST_OLLAMA_PATH + '. The same card cannot be host and guest.' : 'Not available on this Device.' }}
        </p>
        <UnsupportedHint v-if="!gpuReady" :text="gpuExplanation" />
        <DataTable v-else :columns="[{ key: 'gpu', label: 'GPU' }, { key: 'group', label: 'IOMMU group' }, { key: 'actions', label: '' }]">
          <tr v-for="dev in (vm.gpuDevices || [])" :key="dev.pciAddress">
            <td>
              <div style="font-weight:500">{{ dev.label || dev.pciAddress }}</div>
              <div style="font-size:11px;color:var(--text-dim);font-family:var(--font-mono)">{{ dev.pciAddress }}</div>
            </td>
            <td><span class="badge badge-gray">{{ dev.iommuGroup }}</span></td>
            <td style="text-align:right">
              <span v-if="vm?.state === 'running'" style="font-size:12px;color:var(--text-dim)">Stop VM to detach</span>
              <AppButton v-else size="sm" variant="danger" :disabled="gpuLoading || (isMemberDetail && !memberReachable)" @click="gpuDetach(dev)">Detach</AppButton>
            </td>
          </tr>
          <tr v-if="!(vm.gpuDevices || []).length">
            <td colspan="3">
              <EmptyState title="No GPU attached" subtitle="Pass through a PCI GPU. Guest Ollama uses the card at 127.0.0.1:11434." />
            </td>
          </tr>
        </DataTable>
      </div>
    </div>

    <ChatPanel
      v-if="tab === 'chat' && showAgentChat"
      compact
    />
    <ConsolePanel
      v-if="tab === 'console' && showMemberConnect"
      :key="`console-${vmId}-${isMemberDetail ? hostId : 'local'}`"
      :vm-id="vmId"
      :vm-state="vm.state"
      :device="isMemberDetail ? memberDevice : undefined"
    />
    <VNCPanel
      v-if="tab === 'vnc' && showMemberConnect"
      :key="`vnc-${vmId}-${isMemberDetail ? hostId : 'local'}`"
      :vm-id="vmId"
      :vm-state="vm.state"
      :device="isMemberDetail ? memberDevice : undefined"
    />
    <MetricsPanel
      v-if="tab === 'metrics' && vm.state === 'running'"
      :key="`metrics-${vmId}-${isMemberDetail ? hostId : 'local'}`"
      :vm-id="vmId"
      :device="isMemberDetail ? memberDevice : undefined"
    />
    <LogsPanel
      v-if="isMemberDetail && tab === 'logs'"
      :key="`logs-${hostId}-${vmId}`"
      :vm-id="vmId"
      :device="memberDevice"
    />

    <!-- Attach USB Device Modal -->
    <div v-if="usbAvailable && showAttachUSB" class="modal-overlay" @click.self="showAttachUSB = false">
      <div class="modal">
        <h2>Attach USB Device</h2>
        <EmptyState v-if="hostUSBDevices.length === 0" :title="isMemberDetail ? 'No USB devices detected on that Device.' : 'No USB devices detected on this device.'" />
        <DataTable v-else :columns="[{ key: 'device', label: 'Device' }, { key: 'id', label: 'ID' }, { key: 'actions', label: '' }]">
              <tr
                v-for="dev in hostUSBDevices"
                :key="usbDeviceKey(dev)"
                :style="dev.claimedByVMId || dev.attachable === false ? 'opacity:0.5' : ''"
              >
                <td>
                  <div style="font-weight:500">{{ dev.productName || dev.name }}</div>
                  <div v-if="dev.manufacturer" style="font-size:11px;color:var(--text-dim)">{{ dev.manufacturer }}</div>
                  <div v-if="dev.claimedByVMId" style="font-size:11px;color:var(--red)">In use by {{ dev.claimedByVMName }}</div>
                  <div v-else-if="dev.attachable === false" style="font-size:11px;color:var(--text-dim)">{{ dev.excludedReason }}</div>
                  <div v-else-if="dev.idUnstable" style="font-size:11px;color:var(--text-dim)">ID may change if the device is replugged</div>
                </td>
                <td><span class="badge badge-gray" style="font-family:var(--font-mono);font-size:11px">{{ usbDeviceKey(dev) }}</span></td>
                <td style="text-align:right">
                  <span v-if="dev.claimedByVMId" style="font-size:12px;color:var(--text-dim)">In use by {{ dev.claimedByVMName }}</span>
                  <span v-else-if="dev.attachable === false" style="font-size:12px;color:var(--text-dim)">Unavailable</span>
                  <span v-else-if="vm?.state === 'running'" style="font-size:12px;color:var(--text-dim)">Stop VM to attach</span>
                  <AppButton v-else variant="primary" size="sm" :disabled="usbLoading" @click="usbAttach(dev)">Attach</AppButton>
                </td>
              </tr>
        </DataTable>
        <div class="modal-actions">
          <AppButton @click="showAttachUSB = false">Close</AppButton>
        </div>
      </div>
    </div>

    <div v-if="gpuReady && showAttachGPU" class="modal-overlay" @click.self="showAttachGPU = false">
      <div class="modal">
        <h2>Attach GPU</h2>
        <EmptyState v-if="hostGPUDevices.length === 0" :title="isMemberDetail ? 'No GPUs in an IOMMU group on that Device.' : 'No GPUs in an IOMMU group on this Device.'" />
        <DataTable v-else :columns="[{ key: 'gpu', label: 'GPU' }, { key: 'group', label: 'IOMMU group' }, { key: 'actions', label: '' }]">
          <tr
            v-for="dev in hostGPUDevices"
            :key="dev.pciAddress"
            :style="dev.claimedByVMId || dev.attachable === false ? 'opacity:0.5' : ''"
          >
            <td>
              <div style="font-weight:500">{{ dev.name }}</div>
              <div style="font-size:11px;color:var(--text-dim);font-family:var(--font-mono)">{{ dev.pciAddress }}</div>
              <div v-if="dev.claimedByVMId" style="font-size:11px;color:var(--red)">In use by {{ dev.claimedByVMName }}</div>
              <div v-else-if="dev.inUseByHost" style="font-size:11px;color:var(--red)">{{ gpuHostOccupancyLabel(true) }}</div>
              <div v-else-if="dev.attachable === false" style="font-size:11px;color:var(--text-dim)">{{ dev.excludedReason }}</div>
            </td>
            <td><span class="badge badge-gray">{{ dev.iommuGroup }}</span></td>
            <td style="text-align:right">
              <span v-if="dev.claimedByVMId" style="font-size:12px;color:var(--text-dim)">In use</span>
              <span v-else-if="dev.attachable === false" style="font-size:12px;color:var(--text-dim)">Unavailable</span>
              <span v-else-if="vm?.state === 'running'" style="font-size:12px;color:var(--text-dim)">Stop VM to attach</span>
              <AppButton v-else variant="primary" size="sm" :disabled="gpuLoading" @click="gpuAttach(dev)">Attach</AppButton>
            </td>
          </tr>
        </DataTable>
        <p style="margin-top:16px;font-size:12px;color:var(--text-dim)">GPU changes require a VM restart. Guest Ollama is {{ GUEST_OLLAMA_PATH }}.</p>
        <div class="modal-actions">
          <AppButton @click="showAttachGPU = false">Close</AppButton>
        </div>
      </div>
    </div>

    <!-- Attach Disk Modal -->
    <div v-if="showAttachDisk" class="modal-overlay" @click.self="showAttachDisk = false">
      <div class="modal">
        <h2>Attach Disk</h2>
        <EmptyState v-if="availableDisks.length === 0" title="No available disks" subtitle="Create one on the Disks page first." />
        <DataTable v-else :columns="[{ key: 'name', label: 'Name' }, { key: 'size', label: 'Size' }, { key: 'actions', label: '' }]">
              <tr v-for="disk in availableDisks" :key="disk.id">
                <td style="font-weight:500">{{ disk.name }}</td>
                <td class="mono">{{ formatBytes(disk.sizeBytes) }}</td>
                <td>
                  <span v-if="vm?.state === 'running'" style="font-size:12px;color:var(--text-dim)">Stop VM to attach</span>
                  <AppButton v-else variant="primary" size="sm" :disabled="attachLoading" @click="attachDisk(disk.id)">Attach</AppButton>
                </td>
              </tr>
        </DataTable>
        <div class="modal-actions">
          <AppButton @click="showAttachDisk = false">Close</AppButton>
        </div>
      </div>
    </div>
  </div>

  <!-- Folder Picker -->
  <FolderPicker
    v-if="showFolderPicker"
    :modelValue="''"
    @update:modelValue="addSharedPath($event); showFolderPicker = false"
    @close="showFolderPicker = false"
  />

  <ConfirmDialog
    v-if="stopConfirm"
    :title="stopConfirm.method === 'force' ? 'Force Stop VM' : 'Shutdown VM'"
    :message="`Are you sure you want to ${stopConfirm.method === 'force' ? 'force stop' : 'shut down'} ${vm?.name}?${stopConfirm.method === 'force' ? ' This may cause data loss.' : ''}`"
    :confirm-label="stopConfirm.method === 'force' ? 'Force Stop' : 'Shutdown'"
    :danger="stopConfirm.method === 'force'"
    :loading="stopLoading"
    @confirm="confirmStop"
    @cancel="stopConfirm = null"
  />

  <ConfirmDialog
    v-if="confirmDetachDisk"
    title="Detach Disk"
    message="Detach this disk from the VM? The disk will not be deleted."
    confirm-label="Detach"
    :danger="false"
    :loading="detaching"
    @confirm="doDetachDisk"
    @cancel="confirmDetachDisk = null"
  />

  <ConfirmDialog
    v-if="confirmRemoveShare"
    title="Remove Shared Folder"
    :message="`Remove shared folder &quot;${confirmRemoveShare}&quot; from this VM?`"
    confirm-label="Remove"
    :danger="true"
    :loading="removingShare"
    @confirm="doRemoveSharedPath"
    @cancel="confirmRemoveShare = null"
  />

  <!-- Edit Settings Modal -->
  <div v-if="showEditModal" class="modal-overlay" @click.self="!editSaving && (showEditModal = false)">
    <div class="modal" style="max-width:480px">
      <h2>Edit Settings</h2>
      <div class="edit-form">
        <div class="edit-field">
          <label>Description</label>
          <input v-model="editDraft.description" placeholder="Add a description..." />
        </div>
        <div class="edit-field">
          <label>CPU Cores<template v-if="editCpuMax"> (max {{ editCpuMax }})</template></label>
          <input
            v-model.number="editDraft.cpuCount"
            type="number"
            min="1"
            :max="editCpuMax"
          />
        </div>
        <div class="edit-field">
          <label>Memory (MB)</label>
          <input v-model.number="editDraft.memoryMB" type="number" min="128" step="128" />
        </div>
        <div class="edit-field">
          <label>Boot Order</label>
          <AppSelect v-model="editDraft.bootOrder">
            <option value="cd">CD-ROM first (cd)</option>
            <option value="dc">Disk first (dc)</option>
            <option value="c">Disk only (c)</option>
            <option value="d">CD-ROM only (d)</option>
            <option value="n">Network (n)</option>
            <option value="nc">Network, then disk (nc)</option>
          </AppSelect>
        </div>
        <div class="edit-field">
          <label>Network</label>
          <AppSelect v-model="editDraft.networkId" :disabled="isMemberDetail && !memberReachable">
            <option v-for="n in detailNetworks" :key="n.id" :value="n.id">{{ n.name }} ({{ n.mode }})</option>
          </AppSelect>
        </div>
      </div>
      <div class="modal-actions">
        <AppButton :disabled="editSaving" @click="showEditModal = false">Cancel</AppButton>
        <AppButton variant="primary" :loading="editSaving" loading-text="Saving..." @click="saveEdit">Save</AppButton>
      </div>
    </div>
  </div>

  <!-- Port Forward Editor Modal -->
  <div v-if="showPortForwardEditor" class="modal-overlay" @click.self="!pfSaving && (showPortForwardEditor = false)">
    <div class="modal" style="max-width:480px">
      <h2>Port Forwards</h2>
      <p style="font-size:12px;color:var(--text-secondary);margin-bottom:12px">Forward host ports to guest ports (NAT mode only).</p>
      <PortForwardEditor v-model="editPortForwards" />
      <div class="modal-actions">
        <AppButton :disabled="pfSaving" @click="showPortForwardEditor = false">Cancel</AppButton>
        <AppButton variant="primary" :loading="pfSaving" loading-text="Saving..." @click="savePortForwards">Save</AppButton>
      </div>
    </div>
  </div>

  <!-- Delete VM Dialog -->
  <div v-if="showResetDialog" class="modal-overlay" @click.self="showResetDialog = false">
    <div class="modal" style="max-width:420px">
      <h2>Reset to Library image</h2>
      <p style="color:var(--text-secondary);font-size:13px;margin-bottom:16px">
        Replace the boot disk with a fresh Coding Agent image. Guest files that were not pushed are lost.
      </p>
      <div class="modal-actions">
        <AppButton @click="showResetDialog = false">Cancel</AppButton>
        <AppButton variant="danger" :disabled="controlDisabled" @click="showResetDialog = false; action('reset', () => sessionAction('reset'))">Reset</AppButton>
      </div>
    </div>
  </div>
  <div v-if="showBurnDialog" class="modal-overlay" @click.self="showBurnDialog = false">
    <div class="modal" style="max-width:420px">
      <h2>Burn session</h2>
      <p style="color:var(--text-secondary);font-size:13px;margin-bottom:16px">
        Destroy <strong>{{ vm?.name }}</strong> and unload the local-model grant. This does not keep the disk.
      </p>
      <div class="modal-actions">
        <AppButton @click="showBurnDialog = false">Cancel</AppButton>
        <AppButton variant="danger" :disabled="controlDisabled" @click="showBurnDialog = false; action('burn', () => sessionAction('burn'))">Burn</AppButton>
      </div>
    </div>
  </div>
  <div v-if="showDeleteDialog" class="modal-overlay" @click.self="!deletingVM && (showDeleteDialog = false)">
    <div class="modal" style="max-width:420px">
      <h2>Delete VM</h2>
      <p style="color:var(--text-secondary);font-size:13px;margin-bottom:16px">
        Are you sure you want to delete <strong>{{ vm?.name }}</strong>? This will remove the VM configuration, cloud-init data, and EFI variables.
      </p>
      <label style="display:flex;align-items:center;gap:8px;font-size:13px;padding:10px 12px;background:var(--bg);border-radius:var(--radius-sm);cursor:pointer">
        <input type="checkbox" v-model="keepDisk" :disabled="deletingVM" style="width:16px;height:16px;cursor:pointer" />
        Keep boot disk ({{ allDisks.find(d => d.id === vm?.bootDiskId)?.name || 'disk' }})
      </label>
      <p style="font-size:11px;color:var(--text-dim);margin-top:6px;padding-left:4px">
        {{ keepDisk ? 'The disk file will be preserved and available for use with other VMs.' : 'The boot disk file will be permanently deleted.' }}
      </p>
      <div class="modal-actions">
        <AppButton :disabled="deletingVM" @click="showDeleteDialog = false">Cancel</AppButton>
        <AppButton variant="danger" :loading="deletingVM" loading-text="Deleting..." @click="deleteVM">Delete VM</AppButton>
      </div>
    </div>
  </div>
</template>

<style scoped>
.empty p,
.list-error {
  color: var(--text-secondary);
  font-size: 13px;
  line-height: 1.5;
}
.list-error { margin: 0 0 16px; }
.edit-form {
  display: flex;
  flex-direction: column;
  gap: 14px;
  margin-bottom: 20px;
}
.edit-field {
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.edit-field label {
  font-size: 12px;
  font-weight: 600;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.edit-field input,
.edit-field select {
  width: 100%;
}
.pending-banner {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 14px;
  margin-bottom: 16px;
  background: var(--amber-muted);
  border: 1px solid rgba(245, 158, 11, 0.25);
  border-radius: var(--radius-sm);
  font-size: 13px;
  color: var(--amber, #f59e0b);
}
.session-nopush {
  color: #f87171;
  border-color: rgba(248, 113, 113, 0.4);
  background: rgba(248, 113, 113, 0.12);
  font-weight: 600;
}
.emu-banner {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  padding: 10px 14px;
  margin-bottom: 16px;
  background: var(--amber-muted);
  border: 1px solid rgba(245, 158, 11, 0.25);
  border-radius: var(--radius-sm);
  font-size: 13px;
  color: var(--amber, #f59e0b);
}
.bridge-banner {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 14px;
  margin-bottom: 16px;
  background: var(--red-muted, rgba(248, 113, 113, 0.1));
  border: 1px solid rgba(248, 113, 113, 0.25);
  border-radius: var(--radius-sm);
  font-size: 13px;
  color: var(--red, #f87171);
}
.detail-grid {
  display: flex;
  flex-direction: column;
  gap: 0;
}
.detail-row {
  display: flex;
  align-items: center;
  padding: 14px 0;
  border-bottom: 1px solid var(--border-subtle);
}
.detail-row:last-child { border-bottom: none; }
.detail-row > span:not(.detail-label) {
  flex: 1;
  min-width: 0;
}
.detail-row .detail-editable {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.detail-label {
  width: 160px;
  flex-shrink: 0;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.ci-log-output {
  font-family: var(--font-mono);
  font-size: 11px;
  line-height: 1.6;
  color: var(--text-secondary);
  padding: 14px 16px;
  margin: 0;
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 500px;
  overflow-y: auto;
}
.badge-green {
  background: rgba(34, 197, 94, 0.15);
  color: var(--green);
}
</style>
