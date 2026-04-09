<script setup lang="ts">
import { ref, onMounted, onUnmounted, computed, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useVMStore } from '../stores/vms'
import api, { getWSTicket } from '../api/client'
import type { Disk, DiskUsage, Network, GuestInfo, Image, PortForwardRule, BridgeInfo, HostUSBDevice, USBPassthroughDevice } from '../api/types'
import PortForwardEditor from '../components/PortForwardEditor.vue'
import { useToastStore } from '../stores/toast'
import ConsolePanel from '../components/ConsolePanel.vue'
import VNCPanel from '../components/VNCPanel.vue'
import MetricsPanel from '../components/MetricsPanel.vue'
import FolderPicker from '../components/FolderPicker.vue'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppIcon from '../components/ui/AppIcon.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import StopButtonGroup from '../components/ui/StopButtonGroup.vue'
import { formatBytes } from '../utils/format'

const route = useRoute()
const router = useRouter()
const store = useVMStore()
const vmId = computed(() => route.params.id as string)
const tab = ref((route.query.tab as string) || 'overview')

watch(tab, (value) => {
  router.replace({ query: { ...route.query, tab: value === 'overview' ? undefined : value } })
})
const vm = computed(() => store.vms.find(v => v.id === vmId.value))
const actionLoading = ref('')
const showEditModal = ref(false)
const editDraft = ref({
  description: '',
  cpuCount: 1,
  memoryMB: 512,
  bootOrder: 'cd',
  networkId: '',
})
const editSaving = ref(false)

// Disk management
const allDisks = ref<Disk[]>([])
const diskUsages = ref<Record<string, DiskUsage>>({})
const showAttachDisk = ref(false)
const attachLoading = ref(false)

// Network management
const allNetworks = ref<Network[]>([])
const bridges = ref<BridgeInfo[]>([])
const bridgeLoading = ref<string | null>(null)

// Guest agent info (includes IP, OS, filesystem, etc.)
const guestInfo = ref<GuestInfo | null>(null)

// USB passthrough
const hostUSBDevices = ref<HostUSBDevice[]>([])
const showAttachUSB = ref(false)
const usbLoading = ref(false)

// Port forwards
const showPortForwardEditor = ref(false)
const editPortForwards = ref<PortForwardRule[]>([])
const pfSaving = ref(false)

function openPortForwardEditor() {
  editPortForwards.value = vm.value?.portForwards ? [...vm.value.portForwards] : []
  showPortForwardEditor.value = true
}

async function savePortForwards() {
  pfSaving.value = true
  try {
    await store.update(vmId.value, { portForwards: editPortForwards.value } as any)
    showPortForwardEditor.value = false
    await store.fetchOne(vmId.value)
    if (vm.value?.state === 'running') {
      toast.show('Port forward changes require a VM restart to take effect.', { type: 'info' })
    }
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    pfSaving.value = false
  }
}

const availableDisks = computed(() => {
  if (!vm.value) return []
  const attached = new Set([vm.value.bootDiskId, ...(vm.value.additionalDiskIds || [])])
  return allDisks.value.filter(d => !attached.has(d.id))
})

const additionalDiskDetails = computed(() => {
  if (!vm.value?.additionalDiskIds) return []
  return vm.value.additionalDiskIds
    .map(diskId => allDisks.value.find(d => d.id === diskId))
    .filter(Boolean) as Disk[]
})

// Images (for ISO name lookup)
const allImages = ref<Image[]>([])

async function fetchDisks() {
  const { data } = await api.get('/disks')
  allDisks.value = data
  // Fetch usage for VM's disks
  const vmDiskIds = [vm.value?.bootDiskId, ...(vm.value?.additionalDiskIds || [])].filter(Boolean) as string[]
  const usages: Record<string, DiskUsage> = {}
  await Promise.all(vmDiskIds.map(async (diskId) => {
    try {
      const { data: usage } = await api.get(`/disks/${diskId}/usage`)
      usages[diskId] = usage
    } catch { /* ignore */ }
  }))
  diskUsages.value = usages
}

async function fetchNetworks() {
  const { data } = await api.get('/networks')
  allNetworks.value = data
}

async function fetchBridges() {
  try {
    const { data } = await api.get('/system/bridges')
    bridges.value = data
  } catch {}
}

const bridgeNotReady = computed(() => {
  if (!currentNetwork.value || currentNetwork.value.mode !== 'bridged' || !currentNetwork.value.bridge) return false
  const info = bridges.value.find(b => b.interface === currentNetwork.value!.bridge)
  return !info || info.status !== 'active'
})

const bridgeStatus = computed(() => {
  if (!currentNetwork.value?.bridge) return null
  return bridges.value.find(b => b.interface === currentNetwork.value!.bridge)?.status || 'not_configured'
})

async function setupBridgeFromDetail() {
  if (!currentNetwork.value?.bridge) return
  bridgeLoading.value = currentNetwork.value.bridge
  try {
    await api.post('/system/bridges', { interface: currentNetwork.value.bridge })
    toast.success(`Bridge installed for ${currentNetwork.value.bridge}`)
    await fetchBridges()
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    bridgeLoading.value = null
  }
}

async function fetchImages() {
  const { data } = await api.get('/images')
  allImages.value = data
}

const isoImages = computed(() => {
  const ids = vm.value?.isoIds ?? (vm.value?.isoId ? [vm.value.isoId] : [])
  return ids.map(id => allImages.value.find(i => i.id === id) || { id, name: id.slice(0, 8) + '...', arch: 'arm64' } as any)
})

const availableIsos = computed(() =>
  allImages.value.filter(i => i.imageType === 'iso' && i.status === 'ready' && !isoImages.value.some(iso => iso.id === i.id))
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

async function fetchGuestInfo() {
  if (vm.value?.state !== 'running') { guestInfo.value = null; return }
  try {
    const { data } = await api.get(`/vms/${vmId.value}/guest-info`)
    guestInfo.value = data
  } catch { guestInfo.value = null }
}



async function fetchUSBDevices() {
  try {
    const { data } = await api.get('/system/usb-devices')
    hostUSBDevices.value = data
  } catch { hostUSBDevices.value = [] }
}

async function usbAttach(dev: HostUSBDevice) {
  usbLoading.value = true
  try {
    const device: USBPassthroughDevice = { vendorId: dev.vendorId, productId: dev.productId, label: dev.name }
    const current = vm.value?.usbDevices || []
    await store.update(vmId.value, { usbDevices: [...current, device] } as any)
    await store.fetchOne(vmId.value)
    await fetchUSBDevices()
    showAttachUSB.value = false
    if (vm.value?.state === 'running') {
      toast.show(`USB device "${dev.name}" added — restart the VM to apply.`, { type: 'info' })
    } else {
      toast.success(`USB device "${dev.name}" attached`)
    }
  } catch (e: any) { toast.error(e.response?.data?.reason || e.message) }
  finally { usbLoading.value = false }
}

async function usbDetach(dev: USBPassthroughDevice) {
  usbLoading.value = true
  try {
    const current = vm.value?.usbDevices || []
    await store.update(vmId.value, {
      usbDevices: current.filter(d => !(d.vendorId === dev.vendorId && d.productId === dev.productId))
    } as any)
    await store.fetchOne(vmId.value)
    await fetchUSBDevices()
    if (vm.value?.state === 'running') {
      toast.show('USB device removed — restart the VM to apply.', { type: 'info' })
    } else {
      toast.success(`USB device detached`)
    }
  } catch (e: any) { toast.error(e.response?.data?.reason || e.message) }
  finally { usbLoading.value = false }
}

let pollInterval: number | undefined
let stateSSE: EventSource | null = null

let sseReconnectTimeout: ReturnType<typeof setTimeout> | null = null
let detailLoadVersion = 0

function stopRealtimeSync() {
  if (pollInterval) {
    clearInterval(pollInterval)
    pollInterval = undefined
  }
  if (sseReconnectTimeout) {
    clearTimeout(sseReconnectTimeout)
    sseReconnectTimeout = null
  }
  stateSSE?.close()
  stateSSE = null
}

async function connectStateSSE() {
  stateSSE?.close()
  stateSSE = null
  const currentId = vmId.value
  let ticket: string
  try { ticket = await getWSTicket(currentId) } catch { return }
  if (currentId !== vmId.value) return
  const es = new EventSource(`/api/vms/${currentId}/state?ticket=${ticket}`)
  stateSSE = es
  es.onmessage = (e) => {
    try {
      const event = JSON.parse(e.data) as { id: string; state: string }
      const v = store.vms.find(v => v.id === event.id)
      if (v) v.state = event.state as typeof v.state
      fetchGuestInfo()
    } catch {}
  }
  es.onerror = () => {
    // EventSource natively retries on transient errors, but the ticket is
    // single-use so native retries will 401. Close and reconnect with a fresh ticket.
    es.close()
    stateSSE = null
    if (sseReconnectTimeout) clearTimeout(sseReconnectTimeout)
    sseReconnectTimeout = setTimeout(() => {
      sseReconnectTimeout = null
      if (currentId === vmId.value) {
        connectStateSSE()
      }
    }, 5000)
  }
}

async function loadVMDetail() {
  const loadVersion = ++detailLoadVersion
  stopRealtimeSync()
  guestInfo.value = null
  diskUsages.value = {}
  try {
    await Promise.all([
      store.fetchOne(vmId.value),
      fetchNetworks(),
      fetchImages(),
      fetchBridges(),
    ])
    if (loadVersion !== detailLoadVersion) return

    await fetchDisks()
    if (loadVersion !== detailLoadVersion) return

    await fetchGuestInfo()
    if (loadVersion !== detailLoadVersion) return

    connectStateSSE()
    pollInterval = window.setInterval(() => {
      store.fetchOne(vmId.value).then(fetchGuestInfo).catch(() => {})
      fetchBridges()
    }, 15000)
  } catch (e: any) {
    if (loadVersion === detailLoadVersion) {
      toast.error(e.response?.data?.reason || e.message)
    }
  }
}

onMounted(() => {
  void loadVMDetail()
})

watch(vmId, (newId, oldId) => {
  if (newId !== oldId) {
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
    const reason = e.response?.data?.reason || e.message
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
  stopConfirm.value = { method }
}

async function confirmStop() {
  if (!stopConfirm.value) return
  const method = stopConfirm.value.method
  stopConfirm.value = null
  try {
    await store.stop(vmId.value, { method })
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
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
    toast.error(e.response?.data?.reason || e.message)
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
    await Promise.all([
      store.update(vmId.value, { sharedPaths: current.filter(p => p !== path) } as any),
      new Promise(r => setTimeout(r, 400))
    ])
  } finally {
    removingShare.value = false
    confirmRemoveShare.value = null
  }
}

function openEditModal() {
  editDraft.value = {
    description: vm.value?.description || '',
    cpuCount: vm.value?.cpuCount || 1,
    memoryMB: vm.value?.memoryMB || 512,
    bootOrder: vm.value?.bootOrder || 'cd',
    networkId: vm.value?.networkId || defaultNetwork.value?.id || '',
  }
  showEditModal.value = true
}

async function saveEdit() {
  editSaving.value = true
  try {
    await store.update(vmId.value, {
      description: editDraft.value.description,
      cpuCount: editDraft.value.cpuCount,
      memoryMB: editDraft.value.memoryMB,
      bootOrder: editDraft.value.bootOrder,
      networkId: editDraft.value.networkId,
    } as any)
    showEditModal.value = false
    await store.fetchOne(vmId.value)
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    editSaving.value = false
  }
}

async function attachDisk(diskId: string) {
  attachLoading.value = true
  try {
    const current = vm.value?.additionalDiskIds || []
    await store.update(vmId.value, { additionalDiskIds: [...current, diskId] } as any)
    showAttachDisk.value = false
    await store.fetchOne(vmId.value)
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
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
    await Promise.all([
      store.update(vmId.value, { additionalDiskIds: current.filter(d => d !== diskId) } as any).then(() => store.fetchOne(vmId.value)),
      new Promise(r => setTimeout(r, 400))
    ])
  } finally {
    detaching.value = false
    confirmDetachDisk.value = null
  }
}

const defaultNetwork = computed(() => allNetworks.value.find(n => n.isDefault))


const currentNetwork = computed(() => {
  if (!vm.value?.networkId) return defaultNetwork.value || null
  return allNetworks.value.find(n => n.id === vm.value!.networkId) || null
})

</script>

<template>
  <div v-if="!vm" class="empty">
    <p>Loading...</p>
  </div>
  <div v-else>
    <div class="page-header">
      <div style="display:flex;align-items:center;gap:10px">
        <button class="back-icon" @click="router.push('/vms')" title="Back to VMs">
          <AppIcon name="chevron-left" :size="18" />
        </button>
        <h1>{{ vm.name }}</h1>
      </div>
      <div style="display: flex; gap: 8px; align-items: center">
        <span class="status-pill" :class="vm.state">{{ vm.state }}</span>
        <AppButton v-if="vm.state === 'stopped' || vm.state === 'error'" variant="primary"
          :disabled="!!actionLoading" @click="action('start', () => store.start(vmId))">Start</AppButton>
        <StopButtonGroup v-if="vm.state === 'running'" :loading="!!actionLoading" @stop="requestStop($event)" />
        <AppButton v-if="vm.state === 'running'"
          :disabled="!!actionLoading" @click="action('restart', () => store.restart(vmId))">Restart</AppButton>
        <AppButton v-if="vm.state === 'stopped' || vm.state === 'error'" variant="danger" :disabled="!!actionLoading" @click="showDeleteDialog = true; keepDisk = false">Delete</AppButton>
      </div>
    </div>

    <div class="tabs">
      <div class="tab" :class="{ active: tab === 'overview' }" @click="tab = 'overview'">Overview</div>
      <div class="tab" :class="{ active: tab === 'console' }" @click="tab = 'console'">Console</div>
      <div class="tab" :class="{ active: tab === 'vnc' }" @click="tab = 'vnc'">VNC</div>
      <div v-if="vm.state === 'running'" class="tab" :class="{ active: tab === 'metrics' }" @click="tab = 'metrics'">Metrics</div>
    </div>

    <div v-if="vm.pendingChanges" class="pending-banner">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
      </svg>
      Configuration changed. Restart the VM to apply new settings.
    </div>

    <div v-if="bridgeNotReady && (vm.state === 'stopped' || vm.state === 'error')" class="bridge-banner">
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        <path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>
      </svg>
      <span v-if="bridgeStatus === 'installed'">Bridge daemon is not running for <strong>{{ currentNetwork?.bridge }}</strong>. The VM cannot start until the daemon is active.</span>
      <span v-else>Bridge is not configured for <strong>{{ currentNetwork?.bridge }}</strong>. The VM cannot start until the bridge is set up.</span>
      <AppButton size="sm" style="margin-left:auto;flex-shrink:0" :loading="!!bridgeLoading" loading-text="Setting up..." @click="setupBridgeFromDetail">Setup Bridge</AppButton>
    </div>

    <div v-if="tab === 'overview'">
      <div class="card">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:4px">
          <div></div>
          <AppButton size="sm" @click="openEditModal">Edit Settings</AppButton>
        </div>
        <div class="detail-grid">
          <div class="detail-row">
            <span class="detail-label">Type</span>
            <span><span class="badge badge-gray">{{ vm.vmType.startsWith('windows') ? 'Windows' : 'Linux' }}</span></span>
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
                <template v-if="currentNetwork.mode === 'bridged' && currentNetwork.bridge">
                  <span class="mono" style="color:var(--text-dim);font-size:12px">{{ currentNetwork.bridge }}</span>
                  <span v-if="bridgeStatus === 'active'" class="badge badge-green">active</span>
                  <span v-else-if="bridgeStatus === 'installed'" class="badge badge-accent">installed</span>
                  <span v-else class="badge badge-gray">no bridge</span>
                </template>
              </template>
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
              <AppButton size="sm" @click="openPortForwardEditor">Edit</AppButton>
            </span>
          </div>
          <div v-if="currentNetwork?.mode === 'bridged' && (vm.portForwards?.length ?? 0) > 0" class="detail-row">
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
                <span style="color:var(--text-dim);font-size:12px">waiting for guest agent...</span>
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
                  <span class="badge badge-gray">{{ iso.arch }}</span>
                </span>
                <AppButton size="sm" :disabled="!!actionLoading"
                  @click="action('detach ISO', () => store.detachISO(vmId, iso.id))">Detach</AppButton>
              </div>
              <div v-if="isoImages.length === 0" style="font-size:12px;color:var(--text-dim)">No ISOs attached</div>
              <div v-if="showIsoAttach" style="display:flex;gap:6px;align-items:end;margin-top:4px">
                <AppSelect v-model="attachIsoId" size="sm" style="flex:1">
                  <option value="" disabled>Select ISO...</option>
                  <option v-for="img in availableIsos" :key="img.id" :value="img.id">{{ img.name }}</option>
                </AppSelect>
                <AppButton variant="primary" size="sm" :disabled="!attachIsoId || !!actionLoading" @click="doAttachISO">Attach</AppButton>
                <AppButton size="sm" @click="showIsoAttach = false; attachIsoId = ''">Cancel</AppButton>
              </div>
              <AppButton v-else size="sm" icon="plus" style="align-self:flex-start;margin-top:2px" @click="showIsoAttach = true; fetchImages()">Attach ISO</AppButton>
            </span>
          </div>
          <div v-if="vm.macAddress" class="detail-row">
            <span class="detail-label">MAC Address</span>
            <span class="mono" style="color:var(--text-secondary)">{{ vm.macAddress }}</span>
          </div>
          <div v-if="vm.state === 'running' && guestInfo?.available && guestInfo?.ipAddresses?.length" class="detail-row">
            <span class="detail-label">IP Address</span>
            <span style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
              <span v-for="ip in guestInfo.ipAddresses" :key="ip" class="badge badge-accent" style="font-variant-numeric:tabular-nums">{{ ip }}</span>
            </span>
          </div>
          <div class="detail-row">
            <span class="detail-label">Created</span>
            <span style="color:var(--text-secondary)">{{ new Date(vm.createdAt).toLocaleString() }}</span>
          </div>
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
          <AppButton size="sm" icon="plus" @click="showAttachDisk = true; fetchDisks()">Attach Disk</AppButton>
        </div>
        <DataTable :columns="[{ key: 'name', label: 'Name' }, { key: 'format', label: 'Format' }, { key: 'provisioned', label: 'Provisioned' }, { key: 'used', label: 'Used' }, { key: 'role', label: 'Role' }, { key: 'actions', label: '' }]">
              <!-- Boot disk -->
              <tr>
                <td style="font-weight:500">
                  <a href="#" @click.prevent="router.push('/disks')" style="color:var(--accent);text-decoration:none">
                    {{ allDisks.find(d => d.id === vm!.bootDiskId)?.name || vm!.bootDiskId.slice(0,8) + '...' }}
                  </a>
                </td>
                <td><span class="badge badge-gray">qcow2</span></td>
                <td class="mono">{{ allDisks.find(d => d.id === vm!.bootDiskId) ? formatBytes(allDisks.find(d => d.id === vm!.bootDiskId)!.sizeBytes) : '-' }}</td>
                <td class="mono">
                  <template v-if="diskUsages[vm!.bootDiskId]">{{ formatBytes(diskUsages[vm!.bootDiskId].actualSizeBytes) }}</template>
                  <span v-else style="color:var(--text-dim)">-</span>
                </td>
                <td><span class="badge badge-accent">Boot</span></td>
                <td></td>
              </tr>
              <!-- Additional disks -->
              <tr v-for="disk in additionalDiskDetails" :key="disk.id">
                <td style="font-weight:500">
                  <a href="#" @click.prevent="router.push('/disks')" style="color:var(--accent);text-decoration:none">{{ disk.name }}</a>
                </td>
                <td><span class="badge badge-gray">{{ disk.format }}</span></td>
                <td class="mono">{{ formatBytes(disk.sizeBytes) }}</td>
                <td class="mono">
                  <template v-if="diskUsages[disk.id]">{{ formatBytes(diskUsages[disk.id].actualSizeBytes) }}</template>
                  <span v-else style="color:var(--text-dim)">-</span>
                </td>
                <td><span class="badge badge-blue">Extra</span></td>
                <td style="text-align:right">
                  <span v-if="vm?.state === 'running'" style="font-size:12px;color:var(--text-dim)">Stop VM to detach</span>
                  <AppButton v-else size="sm" @click="detachDisk(disk.id)">Detach</AppButton>
                </td>
              </tr>
              <tr v-if="!additionalDiskDetails.length">
                <td colspan="6"><EmptyState title="No additional disks attached" /></td>
              </tr>
        </DataTable>
      </div>

      <!-- Shared Folders Section -->
      <div style="margin-top:20px">
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
      <div style="margin-top:20px">
        <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:12px">
          <h2 style="font-size:16px;font-weight:700">USB Devices</h2>
          <AppButton size="sm" icon="plus" @click="showAttachUSB = true; fetchUSBDevices()">Attach USB Device</AppButton>
        </div>
        <DataTable :columns="[{ key: 'device', label: 'Device' }, { key: 'vendor', label: 'Vendor ID' }, { key: 'product', label: 'Product ID' }, { key: 'actions', label: '' }]">
              <tr v-for="dev in (vm.usbDevices || [])" :key="`${dev.vendorId}:${dev.productId}`">
                <td style="font-weight:500">{{ dev.label || `${dev.vendorId}:${dev.productId}` }}</td>
                <td><span class="badge badge-gray" style="font-family:var(--font-mono);font-size:11px">{{ dev.vendorId }}</span></td>
                <td><span class="badge badge-gray" style="font-family:var(--font-mono);font-size:11px">{{ dev.productId }}</span></td>
                <td style="text-align:right">
                  <span v-if="vm?.state === 'running'" style="font-size:12px;color:var(--text-dim)">Stop VM to detach</span>
                  <AppButton v-else size="sm" variant="danger" :disabled="usbLoading" @click="usbDetach(dev)">Detach</AppButton>
                </td>
              </tr>
              <tr v-if="!vm.usbDevices?.length">
                <td colspan="4"><EmptyState title="No USB devices attached" subtitle="Click &quot;Attach USB Device&quot; to pass through a host USB device." /></td>
              </tr>
        </DataTable>
      </div>
    </div>

    <ConsolePanel v-if="tab === 'console'" :key="`console-${vmId}`" :vm-id="vmId" :vm-state="vm.state" />
    <VNCPanel v-if="tab === 'vnc'" :key="`vnc-${vmId}`" :vm-id="vmId" :vm-state="vm.state" />
    <MetricsPanel v-if="tab === 'metrics' && vm.state === 'running'" :key="`metrics-${vmId}`" :vm-id="vmId" />

    <!-- Attach USB Device Modal -->
    <div v-if="showAttachUSB" class="modal-overlay" @click.self="showAttachUSB = false">
      <div class="modal">
        <h2>Attach USB Device</h2>
        <EmptyState v-if="hostUSBDevices.length === 0" title="No USB devices detected on the host." />
        <DataTable v-else :columns="[{ key: 'device', label: 'Device' }, { key: 'vendor', label: 'Vendor' }, { key: 'ids', label: 'IDs' }, { key: 'actions', label: '' }]">
              <tr v-for="dev in hostUSBDevices" :key="`${dev.vendorId}:${dev.productId}`" :style="dev.claimedByVMId ? 'opacity:0.5' : ''">
                <td style="font-weight:500">{{ dev.name }}</td>
                <td style="font-size:12px;color:var(--text-dim)">{{ dev.manufacturer || '---' }}</td>
                <td><span class="badge badge-gray" style="font-family:var(--font-mono);font-size:11px">{{ dev.vendorId }}:{{ dev.productId }}</span></td>
                <td style="text-align:right">
                  <span v-if="dev.claimedByVMId" style="font-size:12px;color:var(--text-dim)">In use by {{ dev.claimedByVMName }}</span>
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
          <label>CPU Cores</label>
          <input v-model.number="editDraft.cpuCount" type="number" min="1" max="32" />
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
          <AppSelect v-model="editDraft.networkId">
            <option v-for="n in allNetworks" :key="n.id" :value="n.id">{{ n.name }} ({{ n.mode }})</option>
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
