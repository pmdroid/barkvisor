<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import api from '../api/client'
import { computed, onMounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import type { DiskSettings, HomeDeviceHealthSnapshot, HostBlockDevice, StorageSummary } from '../api/types'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import FolderPicker from '../components/FolderPicker.vue'
import WorkloadDeviceChip from '../components/home/WorkloadDeviceChip.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import FormError from '../components/ui/FormError.vue'
import GuestCommandAccordion from '../components/ui/GuestCommandAccordion.vue'
import { useCapabilitiesStore } from '../stores/capabilities'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useDeviceDisksStore, type DiskWriteBody, type HomeDiskRow } from '../stores/deviceDisks'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useDiskStore } from '../stores/disks'
import { useToastStore } from '../stores/toast'
import { useVMStore } from '../stores/vms'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { guestResizeCommands } from '../utils/guestAgentInstall'
import { formatBytes } from '../utils/format'
import {
  canCallDeviceAPI,
  deviceBlockDevicesPath,
  deviceDiskSettingsPath,
  isSelfDevice,
} from '../utils/homeDeviceApi'
import { DEVICE_LABEL } from '../utils/terminology'
import { scopeRows } from '../utils/deviceScope'
import { openWorkloadRow, workloadDetailPath } from '../utils/workloadDetail'
import { storeToRefs } from 'pinia'

const router = useRouter()
const toast = useToastStore()
const vmStore = useVMStore()
const diskStore = useDiskStore()
const devicesStore = useDevicesStore()
const deviceScope = useDeviceScopeStore()
const homeDisks = useDeviceDisksStore()
const homeWorkloads = useDeviceWorkloadsStore()
const caps = useCapabilitiesStore()
const { disks, usages: diskUsages, summary: storageSummary } = storeToRefs(diskStore)

const showCreate = ref(false)
const formHostId = ref('')
const newName = ref('')
const newSizeGB = ref(10)
const newFormat = ref('qcow2')
const newDirectory = ref('')
const useBlockDevice = ref(false)
const blockDevicePath = ref('')
const blockDevices = ref<HostBlockDevice[]>([])
const showBlockConfirm = ref(false)
const showCreatePicker = ref(false)
const loading = ref(false)
const error = ref('')

const diskSettings = ref<DiskSettings | null>(null)
const diskDirectoryDraft = ref('')
const diskDirSaving = ref(false)
const showDiskDirPicker = ref(false)
const formDiskDirectory = ref('')
const formContextSeq = ref(0)
const directoryEdited = ref(false)
const directoryForHostId = ref('')

const resizingRow = ref<HomeDiskRow | null>(null)
const resizeSizeGB = ref(0)
const resizeLoading = ref(false)
const resizeError = ref('')
const resizeDone = ref(false)

const deleteTarget = ref<{ id: string; name: string; hostId: string; path: string } | null>(null)
const deleting = ref(false)

const useHomeUnion = computed(() => devicesStore.devices.length > 0)

const homeRows = computed<HomeDiskRow[]>(() => {
  const rows = useHomeUnion.value
    ? homeDisks.homeRows(devicesStore.devices)
    : disks.value.map((disk) => ({
        disk,
        hostId: devicesStore.selfDevice?.hostId || '',
        label: '',
        role: 'self',
        reachable: true,
      }))
  return scopeRows(rows, deviceScope.selectedHostId)
})

const pageLoading = computed(() => {
  if (devicesStore.loading || diskStore.loading) return true
  return devicesStore.devices.some((device) => homeDisks.isLoading(device.hostId))
})

const loadErrors = computed(() =>
  devicesStore.devices
    .map((device) => homeDisks.errorFor(device.hostId))
    .filter((message): message is string => Boolean(message)),
)

type SummaryCard = {
  hostId: string
  label: string
  role: string
  reachable: boolean
  summary: StorageSummary
}

const summaryCards = computed<SummaryCard[]>(() => {
  const cards = useHomeUnion.value
    ? homeDisks.homeSummaries(devicesStore.devices)
    : storageSummary.value
      ? [{
          hostId: devicesStore.selfDevice?.hostId || '',
          label: '',
          role: 'self',
          reachable: true,
          summary: storageSummary.value,
        }]
      : []
  return scopeRows(cards, deviceScope.selectedHostId)
})

const formDevice = computed(() => {
  if (formHostId.value) return devicesStore.deviceByHostId(formHostId.value)
  return devicesStore.selfDevice
})

const formDeviceOptions = computed(() =>
  scopeRows(devicesStore.devices, deviceScope.selectedHostId).map((device) => ({
    value: device.hostId,
    label: isSelfDevice(device) ? `This ${DEVICE_LABEL}` : deviceDisplayLabel(device),
    disabled: !canCallDeviceAPI(device),
  })),
)

function rowKey(row: HomeDiskRow): string {
  return `${row.hostId}:${row.disk.id}`
}

function canMutate(row: HomeDiskRow): boolean {
  return row.reachable
}

function defaultFormHostId(): string {
  if (!deviceScope.isAll) return deviceScope.selectedHostId
  return devicesStore.selfDevice?.hostId
    || devicesStore.devices.find((device) => canCallDeviceAPI(device))?.hostId
    || ''
}

function mutateTarget(hostId: string): HomeDeviceHealthSnapshot | null {
  return devicesStore.deviceByHostId(hostId)
    ?? (hostId ? null : devicesStore.selfDevice)
}

function homeUnionDeviceBlocked(device: HomeDeviceHealthSnapshot | null): boolean {
  return useHomeUnion.value && (!device || !canCallDeviceAPI(device))
}

function isLinuxOs(os: string | null | undefined): boolean {
  return (os || '').toLowerCase() === 'linux'
}

function formIsLinux(): boolean {
  const device = formDevice.value
  return isLinuxOs(device?.platform?.os || (!useHomeUnion.value ? caps.platform : ''))
}

function isBlockDisk(row: HomeDiskRow): boolean {
  return row.disk.path.startsWith('/dev/')
}

function mutateApiTarget(device: HomeDeviceHealthSnapshot | null) {
  if (useHomeUnion.value && device) return device
  return devicesStore.selfDevice ?? { hostId: devicesStore.selfDevice?.hostId || '', role: 'self' }
}

async function loadSelfDiskSettings() {
  const device = devicesStore.selfDevice
  const path = device ? deviceDiskSettingsPath(device) : '/system/disk/settings'
  try {
    const { data } = await api.get<DiskSettings>(path)
    diskSettings.value = data
    diskDirectoryDraft.value = data.diskDirectory
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e, 'Could not load disk directory'))
  }
}

async function saveSelfDiskSettings() {
  diskDirSaving.value = true
  try {
    const device = devicesStore.selfDevice
    const path = device ? deviceDiskSettingsPath(device) : '/system/disk/settings'
    const { data } = await api.put<DiskSettings>(path, {
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

async function resetSelfDiskSettings() {
  diskDirectoryDraft.value = ''
  await saveSelfDiskSettings()
}

async function loadFormDiskContext() {
  const seq = ++formContextSeq.value
  const device = formDevice.value
  const hostId = device?.hostId || ''
  blockDevices.value = []
  if (homeUnionDeviceBlocked(device)) {
    if (seq !== formContextSeq.value) return
    formDiskDirectory.value = ''
    newDirectory.value = ''
    return
  }
  const target = mutateApiTarget(device)
  try {
    const { data } = await api.get<DiskSettings>(deviceDiskSettingsPath(target))
    if (seq !== formContextSeq.value) return
    formDiskDirectory.value = data.diskDirectory
    if (!directoryEdited.value || directoryForHostId.value !== hostId) {
      newDirectory.value = data.diskDirectory
      directoryForHostId.value = hostId
      directoryEdited.value = false
    }
  } catch {
    if (seq !== formContextSeq.value) return
    formDiskDirectory.value = ''
  }
  if (formIsLinux()) {
    try {
      const { data } = await api.get<HostBlockDevice[]>(deviceBlockDevicesPath(target))
      if (seq !== formContextSeq.value) return
      blockDevices.value = data
    } catch {
      if (seq !== formContextSeq.value) return
      blockDevices.value = []
    }
  } else {
    if (seq !== formContextSeq.value) return
    blockDevices.value = []
    useBlockDevice.value = false
    blockDevicePath.value = ''
  }
}

function markDirectoryEdited(value: string) {
  newDirectory.value = value
  directoryEdited.value = true
  directoryForHostId.value = formDevice.value?.hostId || ''
}

const blockDeviceOptions = computed(() =>
  blockDevices.value.map((dev) => ({
    value: dev.path,
    label: `${dev.path}${dev.model ? ` — ${dev.model}` : ''} (${formatBytes(dev.sizeBytes)})${dev.attachable ? '' : ` — ${dev.excludedReason || 'unavailable'}`}`,
    disabled: !dev.attachable,
  })),
)

const selectedBlockDevice = computed(() =>
  blockDevices.value.find((dev) => dev.path === blockDevicePath.value) ?? null,
)

function usageFor(row: HomeDiskRow) {
  if (useHomeUnion.value) return homeDisks.usageFor(row.hostId, row.disk.id)
  return diskUsages.value[row.disk.id]
}

function workloadName(row: HomeDiskRow): string {
  const vmId = row.disk.vmId
  if (!vmId) return ''
  if (useHomeUnion.value) {
    return homeWorkloads.vmFor(row.hostId, vmId)?.name || `${vmId.slice(0, 8)}...`
  }
  return vmStore.vms.find((vm) => vm.id === vmId)?.name || `${vmId.slice(0, 8)}...`
}

function workloadHref(row: HomeDiskRow): string {
  if (!row.disk.vmId) return ''
  return workloadDetailPath({ hostId: row.hostId, role: row.role, vm: { id: row.disk.vmId } })
}

function openWorkload(row: HomeDiskRow) {
  if (!row.disk.vmId) return
  openWorkloadRow((path) => { router.push(path) }, {
    hostId: row.hostId,
    role: row.role,
    vm: { id: row.disk.vmId },
  })
}

function barPct(used: number, total: number): number {
  if (total <= 0) return 0
  return Math.min((used / total) * 100, 100)
}

function volumeOtherPct(summary: StorageSummary): number {
  if (summary.volumeTotalBytes <= 0) return 0
  const other = summary.volumeTotalBytes - summary.volumeAvailableBytes - summary.totalActualBytes
  return Math.min((Math.max(other, 0) / summary.volumeTotalBytes) * 100, 100)
}

async function refreshHomeDisks() {
  await devicesStore.fetchHealth().catch(() => {})
  if (!useHomeUnion.value) {
    await Promise.all([
      diskStore.fetchAll({ withUsage: true }),
      diskStore.fetchSummary(),
      vmStore.fetchAll(),
    ])
    return
  }
  await Promise.all([
    homeDisks.fetchHomeAll(devicesStore.devices),
    homeWorkloads.fetchHomeAll(devicesStore.devices),
  ])
}

onMounted(() => {
  void caps.fetchCapabilities()
  void refreshHomeDisks()
  void loadSelfDiskSettings()
})

watch(formHostId, () => {
  directoryEdited.value = false
  if (showCreate.value) void loadFormDiskContext()
})

watch(showCreate, (open) => {
  if (!open) formContextSeq.value += 1
})

function resetForm() {
  formContextSeq.value += 1
  newName.value = ''
  newSizeGB.value = 10
  newFormat.value = 'qcow2'
  newDirectory.value = ''
  directoryEdited.value = false
  directoryForHostId.value = ''
  formDiskDirectory.value = ''
  blockDevices.value = []
  useBlockDevice.value = false
  blockDevicePath.value = ''
  showBlockConfirm.value = false
  error.value = ''
  formHostId.value = defaultFormHostId()
}

function openCreate() {
  resetForm()
  showCreate.value = true
  void loadFormDiskContext()
}

function createBody(): DiskWriteBody | null {
  if (!newName.value.trim()) { error.value = 'Name required'; return null }
  if (useBlockDevice.value) {
    if (!blockDevicePath.value) { error.value = 'Select a host block device'; return null }
    if (selectedBlockDevice.value && !selectedBlockDevice.value.attachable) {
      error.value = selectedBlockDevice.value.excludedReason || 'Block device is not attachable'
      return null
    }
    return { name: newName.value.trim(), blockDevice: blockDevicePath.value }
  }
  const body: DiskWriteBody = {
    name: newName.value.trim(),
    sizeGB: newSizeGB.value,
    format: newFormat.value,
  }
  const dir = newDirectory.value.trim()
  if (dir && dir !== formDiskDirectory.value) body.directory = dir
  return body
}

async function submitCreate() {
  error.value = ''
  const body = createBody()
  if (!body) return
  if (body.blockDevice && !showBlockConfirm.value) {
    showBlockConfirm.value = true
    return
  }
  const device = formDevice.value
  if (homeUnionDeviceBlocked(device)) {
    error.value = 'Device is unreachable. Workloads on this Device keep running locally.'
    return
  }
  loading.value = true
  try {
    if (useHomeUnion.value && device) {
      await homeDisks.create(device, body)
    } else {
      await diskStore.create(body)
      await diskStore.fetchAll({ withUsage: true })
    }
    showCreate.value = false
    showBlockConfirm.value = false
    resetForm()
  } catch (e: unknown) { error.value = apiErrorMessage(e) }
  finally { loading.value = false }
}

async function createDisk() {
  await submitCreate()
}

function deleteDisk(row: HomeDiskRow) {
  deleteTarget.value = { id: row.disk.id, name: row.disk.name, hostId: row.hostId, path: row.disk.path }
}

async function doDeleteDisk() {
  if (!deleteTarget.value) return
  deleting.value = true
  try {
    const device = mutateTarget(deleteTarget.value.hostId)
    if (homeUnionDeviceBlocked(device)) {
      toast.error('Device is unreachable. Workloads on this Device keep running locally.')
      return
    }
    if (useHomeUnion.value && device) {
      await homeDisks.remove(device, deleteTarget.value.id)
    } else {
      await diskStore.remove(deleteTarget.value.id)
    }
  } catch (e: unknown) { toast.error(apiErrorMessage(e)) }
  finally {
    deleting.value = false
    deleteTarget.value = null
  }
}

function openResize(row: HomeDiskRow) {
  resizingRow.value = row
  resizeSizeGB.value = Math.ceil(row.disk.sizeBytes / (1024 * 1024 * 1024)) + 1
  resizeError.value = ''
  resizeDone.value = false
}

function closeResize() {
  resizingRow.value = null
  resizeDone.value = false
}

async function resizeDisk() {
  if (!resizingRow.value) return
  const device = mutateTarget(resizingRow.value.hostId)
  if (homeUnionDeviceBlocked(device)) {
    resizeError.value = 'Device is unreachable. Workloads on this Device keep running locally.'
    return
  }
  resizeError.value = ''
  resizeLoading.value = true
  try {
    if (useHomeUnion.value && device) {
      await homeDisks.resize(device, resizingRow.value.disk.id, resizeSizeGB.value)
    } else {
      await diskStore.resize(resizingRow.value.disk.id, resizeSizeGB.value)
    }
    resizeDone.value = true
  } catch (e: unknown) { resizeError.value = apiErrorMessage(e) }
  finally { resizeLoading.value = false }
}

</script>

<template>
  <div class="page-header">
    <h1>Disks</h1>
    <AppButton variant="primary" icon="plus" @click="openCreate">Create Disk</AppButton>
  </div>

  <div class="storage-summary" style="padding:16px 20px">
    <div class="form-group" style="margin:0;max-width:720px">
      <label>Default VM disk directory</label>
      <div style="display:flex;gap:8px;align-items:center">
        <input
          v-model="diskDirectoryDraft"
          :disabled="diskDirSaving"
          placeholder="/var/lib/barkvisor/disks"
          style="flex:1"
        />
        <AppButton size="sm" :disabled="diskDirSaving" @click="showDiskDirPicker = true">Browse</AppButton>
        <AppButton size="sm" variant="primary" :disabled="diskDirSaving" :loading="diskDirSaving" @click="saveSelfDiskSettings">Save</AppButton>
        <AppButton size="sm" :disabled="diskDirSaving || diskSettings?.isDefault" @click="resetSelfDiskSettings">Reset</AppButton>
      </div>
      <p style="color:var(--text-dim);font-size:12px;margin:8px 0 0 0">
        New disks on this {{ DEVICE_LABEL }} go here unless Create Disk picks another folder.
      </p>
    </div>
  </div>
  <FolderPicker
    v-if="showDiskDirPicker"
    :model-value="diskDirectoryDraft"
    @update:model-value="diskDirectoryDraft = $event"
    @close="showDiskDirPicker = false"
  />

  <p v-if="loadErrors.length" style="color:var(--red, #ef4444);font-size:13px;margin:0 0 12px">
    {{ loadErrors[0] }}
  </p>

  <div
    v-for="card in summaryCards"
    :key="card.hostId || 'local'"
    class="storage-summary"
  >
    <div class="storage-summary-header">
      <div>
        <WorkloadDeviceChip
          v-if="useHomeUnion"
          :label="card.label"
          :self="card.role === 'self'"
          :reachable="card.reachable"
        />
        <span class="storage-label" :class="{ 'storage-label-after-chip': useHomeUnion }">Disk Usage</span>
        <span class="storage-actual">{{ formatBytes(card.summary.totalActualBytes) }}</span>
        <span class="storage-dim"> used on disk</span>
        <span class="storage-dim"> / {{ formatBytes(card.summary.totalVirtualBytes) }} provisioned</span>
      </div>
      <div>
        <span class="storage-label">System Volume</span>
        <span class="storage-actual">{{ formatBytes(card.summary.volumeTotalBytes - card.summary.volumeAvailableBytes) }}</span>
        <span class="storage-dim"> / {{ formatBytes(card.summary.volumeTotalBytes) }}</span>
        <span class="storage-dim"> ({{ formatBytes(card.summary.volumeAvailableBytes) }} free)</span>
      </div>
    </div>
    <div class="storage-bar">
      <div class="storage-bar-vm" :style="{ width: barPct(card.summary.totalActualBytes, card.summary.volumeTotalBytes) + '%' }" />
      <div class="storage-bar-other" :style="{ width: volumeOtherPct(card.summary) + '%' }" />
    </div>
    <div class="storage-legend">
      <span><span class="legend-dot" style="background:var(--purple)"></span>VM disks</span>
      <span><span class="legend-dot" style="background:var(--text-dim)"></span>Other</span>
      <span><span class="legend-dot" style="background:rgba(255,255,255,0.06)"></span>Free</span>
    </div>
  </div>

  <EmptyState
    v-if="homeRows.length === 0 && !pageLoading"
    icon="disk"
    title="No disks. Disks are created automatically when you create a VM."
  />

  <DataTable v-else-if="homeRows.length > 0" :columns="[
    { key: 'name', label: 'Name' },
    { key: 'device', label: 'Device' },
    { key: 'path', label: 'Path' },
    { key: 'format', label: 'Format' },
    { key: 'provisioned', label: 'Provisioned' },
    { key: 'used', label: 'Used on Disk' },
    { key: 'vm', label: 'VM' },
    { key: 'actions', label: '' },
  ]">
    <tr v-for="row in homeRows" :key="rowKey(row)">
      <td style="font-weight:500">{{ row.disk.name }}</td>
      <td>
        <WorkloadDeviceChip
          :label="row.label"
          :self="row.role === 'self'"
          :reachable="row.reachable"
        />
      </td>
      <td class="mono" :title="row.disk.path" style="max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{{ row.disk.path }}</td>
      <td><span class="badge badge-gray">{{ row.disk.format }}</span></td>
      <td class="mono">{{ formatBytes(row.disk.sizeBytes) }}</td>
      <td class="mono">
        <template v-if="usageFor(row)">
          {{ formatBytes(usageFor(row)!.actualSizeBytes) }}
          <div class="usage-bar">
            <div
              class="usage-bar-fill"
              :style="{ width: barPct(usageFor(row)!.actualSizeBytes, usageFor(row)!.virtualSizeBytes) + '%' }"
            />
          </div>
        </template>
        <span v-else style="color:var(--text-dim)">-</span>
      </td>
      <td>
        <a
          v-if="row.disk.vmId"
          :href="workloadHref(row)"
          @click.prevent="openWorkload(row)"
          style="color:var(--accent);text-decoration:none"
        >
          {{ workloadName(row) }}
        </a>
        <span v-else class="badge badge-gray">Unattached</span>
      </td>
      <td style="text-align:right">
        <div v-if="canMutate(row)" style="display:flex;gap:4px;justify-content:flex-end">
          <AppButton v-if="!isBlockDisk(row)" size="sm" @click="openResize(row)">Resize</AppButton>
          <AppButton v-if="!row.disk.vmId" size="sm" @click="deleteDisk(row)">Delete</AppButton>
        </div>
      </td>
    </tr>
  </DataTable>

  <div v-if="showCreate" class="modal-overlay" @click.self="showCreate = false">
    <div class="modal">
      <h2>Create Disk</h2>
      <div v-if="formDeviceOptions.length > 0" class="form-group">
        <label>{{ DEVICE_LABEL }}</label>
        <AppSelect v-model="formHostId" :options="formDeviceOptions" />
      </div>
      <div class="form-group"><label>Name</label><input v-model="newName" placeholder="data-disk" /></div>
      <label v-if="formIsLinux()" class="form-group" style="display:flex;gap:8px;align-items:center">
        <input v-model="useBlockDevice" type="checkbox" style="width:16px;height:16px" />
        Use host block device
      </label>
      <div v-if="useBlockDevice && formIsLinux()" class="form-group">
        <label>Block device</label>
        <AppSelect v-model="blockDevicePath" :options="blockDeviceOptions" placeholder="Select a device" />
        <p style="color:var(--text-dim);font-size:12px;margin:8px 0 0 0">
          Attaches the device as a raw disk. The host must not be using it.
        </p>
      </div>
      <template v-else>
        <div class="form-group"><label>Size (GB)</label><input v-model.number="newSizeGB" type="number" min="1" /></div>
        <div class="form-group">
          <label>Format</label>
          <AppSelect v-model="newFormat">
            <option value="qcow2">QCOW2 (sparse, supports snapshots)</option>
            <option value="raw">Raw (best I/O performance, full allocation)</option>
          </AppSelect>
        </div>
        <div class="form-group">
          <label>Location</label>
          <div style="display:flex;gap:8px;align-items:center">
            <input
              :value="newDirectory"
              :placeholder="formDiskDirectory || 'Default disk directory'"
              style="flex:1"
              @input="markDirectoryEdited(($event.target as HTMLInputElement).value)"
            />
            <AppButton v-if="!useHomeUnion || isSelfDevice(formDevice || { hostId: '', role: 'self' })" size="sm" @click="showCreatePicker = true">Browse</AppButton>
          </div>
        </div>
      </template>
      <FormError v-if="error" :message="error" />
      <div class="modal-actions">
        <AppButton @click="showCreate = false">Cancel</AppButton>
        <AppButton variant="primary" :disabled="loading" @click="createDisk">{{ loading ? 'Creating...' : 'Create' }}</AppButton>
      </div>
    </div>
  </div>

  <div v-if="resizingRow" class="modal-overlay" @click.self="closeResize">
    <div class="modal" :style="resizeDone ? { maxWidth: '560px' } : {}">
      <h2>{{ resizeDone ? 'Disk Resized' : 'Resize Disk' }}</h2>

      <!-- Before resize -->
      <template v-if="!resizeDone">
        <p style="color:var(--text-secondary);font-size:13px;margin-bottom:16px">
          Resize <strong>{{ resizingRow.disk.name }}</strong> (currently {{ formatBytes(resizingRow.disk.sizeBytes) }}).
          Disks can only grow, not shrink.
        </p>
        <div class="form-group">
          <label>New Size (GB)</label>
          <input v-model.number="resizeSizeGB" type="number" :min="Math.ceil(resizingRow.disk.sizeBytes / (1024*1024*1024)) + 1" />
        </div>
        <FormError v-if="resizeError" :message="resizeError" />
        <div class="modal-actions">
          <AppButton @click="closeResize">Cancel</AppButton>
          <AppButton variant="primary" :disabled="resizeLoading" @click="resizeDisk">{{ resizeLoading ? 'Resizing...' : 'Resize' }}</AppButton>
        </div>
      </template>

      <!-- After resize: show guest commands (PAS-215) -->
      <template v-else>
        <p style="color:var(--green);font-size:13px;margin-bottom:16px">
          The virtual disk has been resized. To use the new space, you need to grow the partition and filesystem inside the guest VM.
        </p>

        <GuestCommandAccordion :groups="guestResizeCommands" />

        <p style="color:var(--text-dim);font-size:11px;margin-top:12px">
          Replace <code style="background:rgba(255,255,255,0.06);padding:1px 4px;border-radius:2px">/dev/vda</code> with your actual device (e.g. <code style="background:rgba(255,255,255,0.06);padding:1px 4px;border-radius:2px">/dev/sda</code>) if different. Use <code style="background:rgba(255,255,255,0.06);padding:1px 4px;border-radius:2px">lsblk</code> to check.
        </p>

        <div class="modal-actions">
          <AppButton variant="primary" @click="closeResize">Done</AppButton>
        </div>
      </template>
    </div>
  </div>

  <FolderPicker
    v-if="showCreatePicker"
    :model-value="newDirectory"
    @update:model-value="markDirectoryEdited($event)"
    @close="showCreatePicker = false"
  />

  <ConfirmDialog
    v-if="showBlockConfirm"
    title="Attach host block device"
    :message="`Pass ${blockDevicePath} through to a VM as a raw disk? The host must not be using this device. BarkVisor will not format or wipe it.`"
    confirm-label="Attach"
    :danger="true"
    :loading="loading"
    @confirm="submitCreate"
    @cancel="showBlockConfirm = false"
  />

  <ConfirmDialog
    v-if="deleteTarget"
    title="Delete Disk"
    :message="deleteTarget.path.startsWith('/dev/') ? `Remove disk &quot;${deleteTarget.name}&quot;? The host block device is not wiped.` : `Delete disk &quot;${deleteTarget.name}&quot;? The disk file will be permanently removed.`"
    confirm-label="Delete"
    :danger="true"
    :loading="deleting"
    @cancel="deleteTarget = null"
    @confirm="doDeleteDisk"
  />
</template>

<style scoped>
.storage-summary {
  background: var(--bg-card);
  backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  padding: 20px;
  margin-bottom: 20px;
}
.storage-summary-header {
  display: flex;
  justify-content: space-between;
  margin-bottom: 12px;
  flex-wrap: wrap;
  gap: 8px;
}
.storage-label {
  font-size: 12px;
  font-weight: 600;
  color: var(--text-secondary);
  margin-right: 8px;
}
.storage-label-after-chip {
  margin-left: 8px;
}
.storage-actual {
  font-size: 13px;
  font-weight: 700;
  font-variant-numeric: tabular-nums;
}
.storage-dim {
  font-size: 12px;
  color: var(--text-dim);
}
.storage-bar {
  height: 8px;
  background: rgba(255,255,255,0.06);
  border-radius: 4px;
  overflow: hidden;
  display: flex;
}
.storage-bar-vm {
  height: 100%;
  background: var(--purple);
  transition: width 0.5s ease;
}
.storage-bar-other {
  height: 100%;
  background: var(--text-dim);
  opacity: 0.4;
  transition: width 0.5s ease;
}
.storage-legend {
  display: flex;
  gap: 16px;
  margin-top: 8px;
  font-size: 11px;
  color: var(--text-dim);
}
.legend-dot {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 2px;
  margin-right: 4px;
  vertical-align: middle;
}
.usage-bar {
  height: 4px;
  background: rgba(255,255,255,0.06);
  border-radius: 2px;
  overflow: hidden;
  margin-top: 4px;
  min-width: 60px;
}
.usage-bar-fill {
  height: 100%;
  background: var(--purple);
  transition: width 0.5s ease;
}
</style>
