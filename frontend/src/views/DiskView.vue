<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { computed, onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import type { HomeDeviceHealthSnapshot, StorageSummary } from '../api/types'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import WorkloadDeviceChip from '../components/home/WorkloadDeviceChip.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import FormError from '../components/ui/FormError.vue'
import GuestCommandAccordion from '../components/ui/GuestCommandAccordion.vue'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useDeviceDisksStore, type HomeDiskRow } from '../stores/deviceDisks'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useDiskStore } from '../stores/disks'
import { useToastStore } from '../stores/toast'
import { useVMStore } from '../stores/vms'
import { deviceDisplayLabel } from '../utils/deviceCompatibility'
import { guestResizeCommands } from '../utils/guestAgentInstall'
import { formatBytes } from '../utils/format'
import { canCallDeviceAPI, isSelfDevice } from '../utils/homeDeviceApi'
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
const { disks, usages: diskUsages, summary: storageSummary } = storeToRefs(diskStore)

const showCreate = ref(false)
const formHostId = ref('')
const newName = ref('')
const newSizeGB = ref(10)
const newFormat = ref('qcow2')
const loading = ref(false)
const error = ref('')

const resizingRow = ref<HomeDiskRow | null>(null)
const resizeSizeGB = ref(0)
const resizeLoading = ref(false)
const resizeError = ref('')
const resizeDone = ref(false)

const deleteTarget = ref<{ id: string; name: string; hostId: string } | null>(null)
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
  void refreshHomeDisks()
})

function resetForm() {
  newName.value = ''
  newSizeGB.value = 10
  newFormat.value = 'qcow2'
  error.value = ''
  formHostId.value = defaultFormHostId()
}

function openCreate() {
  resetForm()
  showCreate.value = true
}

async function createDisk() {
  error.value = ''
  if (!newName.value.trim()) { error.value = 'Name required'; return }
  const device = formDevice.value
  if (homeUnionDeviceBlocked(device)) {
    error.value = 'Device is unreachable. Workloads on this Device keep running locally.'
    return
  }
  loading.value = true
  try {
    const body = {
      name: newName.value.trim(),
      sizeGB: newSizeGB.value,
      format: newFormat.value,
    }
    if (useHomeUnion.value && device) {
      await homeDisks.create(device, body)
    } else {
      await diskStore.create(body)
      await diskStore.fetchAll({ withUsage: true })
    }
    showCreate.value = false
    resetForm()
  } catch (e: unknown) { error.value = apiErrorMessage(e) }
  finally { loading.value = false }
}

function deleteDisk(row: HomeDiskRow) {
  deleteTarget.value = { id: row.disk.id, name: row.disk.name, hostId: row.hostId }
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
          <AppButton size="sm" @click="openResize(row)">Resize</AppButton>
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
      <div class="form-group"><label>Size (GB)</label><input v-model.number="newSizeGB" type="number" min="1" /></div>
      <div class="form-group">
        <label>Format</label>
        <AppSelect v-model="newFormat">
          <option value="qcow2">QCOW2 (sparse, supports snapshots)</option>
          <option value="raw">Raw (best I/O performance, full allocation)</option>
        </AppSelect>
      </div>
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

  <ConfirmDialog
    v-if="deleteTarget"
    title="Delete Disk"
    :message="`Delete disk &quot;${deleteTarget.name}&quot;? The disk file will be permanently removed.`"
    confirm-label="Delete"
    :danger="true"
    :loading="deleting"
    @confirm="doDeleteDisk"
    @cancel="deleteTarget = null"
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
