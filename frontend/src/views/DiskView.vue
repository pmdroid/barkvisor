<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import api from '../api/client'
import type { Disk, DiskUsage, StorageSummary } from '../api/types'
import { useToastStore } from '../stores/toast'
import { useVMStore } from '../stores/vms'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import FormError from '../components/ui/FormError.vue'
import { formatBytes } from '../utils/format'

const router = useRouter()
const toast = useToastStore()
const vmStore = useVMStore()

const disks = ref<Disk[]>([])
const diskUsages = ref<Record<string, DiskUsage>>({})
const storageSummary = ref<StorageSummary | null>(null)
const showCreate = ref(false)
const newName = ref('')
const newSizeGB = ref(10)
const newFormat = ref('qcow2')
const loading = ref(false)
const error = ref('')

// Resize
const resizingDisk = ref<Disk | null>(null)
const resizeSizeGB = ref(0)
const resizeLoading = ref(false)
const resizeError = ref('')
const resizeDone = ref(false)
const guestCmdsOpen = ref<string | null>(null)

async function fetchDisks() {
  const { data } = await api.get('/disks')
  disks.value = data
  // Fetch usage for each disk in parallel
  const usages: Record<string, DiskUsage> = {}
  await Promise.all(data.map(async (d: Disk) => {
    try {
      const { data: usage } = await api.get(`/disks/${d.id}/usage`)
      usages[d.id] = usage
    } catch { /* ignore */ }
  }))
  diskUsages.value = usages
}

async function fetchSummary() {
  try {
    const { data } = await api.get('/disks/summary')
    storageSummary.value = data
  } catch { /* ignore */ }
}

onMounted(() => { fetchDisks(); fetchSummary(); vmStore.fetchAll() })

async function createDisk() {
  error.value = ''
  if (!newName.value.trim()) { error.value = 'Name required'; return }
  loading.value = true
  try {
    await api.post('/disks', { name: newName.value.trim(), sizeGB: newSizeGB.value, format: newFormat.value })
    showCreate.value = false
    newName.value = ''
    newFormat.value = 'qcow2'
    await Promise.all([fetchDisks(), fetchSummary()])
  } catch (e: any) { error.value = e.response?.data?.reason || e.message }
  finally { loading.value = false }
}

const deleteTarget = ref<{ id: string; name: string } | null>(null)
const deleting = ref(false)

function deleteDisk(id: string, name: string) {
  deleteTarget.value = { id, name }
}

async function doDeleteDisk() {
  if (!deleteTarget.value) return
  deleting.value = true
  try {
    const { id } = deleteTarget.value
    await Promise.all([
      api.delete(`/disks/${id}`).then(() => Promise.all([fetchDisks(), fetchSummary()])),
      new Promise(r => setTimeout(r, 400))
    ])
  } catch (e: any) { toast.error(e.response?.data?.reason || e.message) }
  finally {
    deleting.value = false
    deleteTarget.value = null
  }
}

function openResize(disk: Disk) {
  resizingDisk.value = disk
  resizeSizeGB.value = Math.ceil(disk.sizeBytes / (1024 * 1024 * 1024)) + 1
  resizeError.value = ''
  resizeDone.value = false
}

function closeResize() {
  resizingDisk.value = null
  resizeDone.value = false
}

async function resizeDisk() {
  if (!resizingDisk.value) return
  resizeError.value = ''
  resizeLoading.value = true
  try {
    await Promise.all([
      api.post(`/disks/${resizingDisk.value.id}/resize`, { sizeGB: resizeSizeGB.value }),
      new Promise(r => setTimeout(r, 400))
    ])
    resizeDone.value = true
    await Promise.all([fetchDisks(), fetchSummary()])
  } catch (e: any) { resizeError.value = e.response?.data?.reason || e.message }
  finally { resizeLoading.value = false }
}

const guestResizeCommands = [
  { id: 'ubuntu', label: 'Ubuntu / Debian', commands: 'sudo growpart /dev/vda 1\nsudo resize2fs /dev/vda1' },
  { id: 'alpine', label: 'Alpine Linux', commands: 'apk add growpart\ngrowpart /dev/vda 1\nresize2fs /dev/vda1' },
  { id: 'arch', label: 'Arch Linux', commands: 'sudo growpart /dev/vda 1\nsudo resize2fs /dev/vda1' },
  { id: 'rhel', label: 'RHEL / Fedora / CentOS', commands: 'sudo growpart /dev/vda 1\nsudo xfs_growfs /      # XFS (default)\nsudo resize2fs /dev/vda1  # ext4' },
  { id: 'suse', label: 'openSUSE / SLES', commands: 'sudo growpart /dev/vda 1\nsudo xfs_growfs /      # XFS\nsudo resize2fs /dev/vda1  # ext4' },
  { id: 'lvm', label: 'LVM (any distro)', commands: 'sudo growpart /dev/vda 2\nsudo pvresize /dev/vda2\nsudo lvextend -l +100%FREE /dev/mapper/vg0-root\nsudo resize2fs /dev/mapper/vg0-root  # ext4\nsudo xfs_growfs /                    # XFS' },
]

</script>

<template>
  <div class="page-header">
    <h1>Disks</h1>
    <AppButton variant="primary" icon="plus" @click="showCreate = true">Create Disk</AppButton>
  </div>

  <!-- Storage Summary -->
  <div v-if="storageSummary" class="storage-summary">
    <div class="storage-summary-header">
      <div>
        <span class="storage-label">Disk Usage</span>
        <span class="storage-actual">{{ formatBytes(storageSummary.totalActualBytes) }}</span>
        <span class="storage-dim"> used on disk</span>
        <span class="storage-dim"> / {{ formatBytes(storageSummary.totalVirtualBytes) }} provisioned</span>
      </div>
      <div>
        <span class="storage-label">System Volume</span>
        <span class="storage-actual">{{ formatBytes(storageSummary.volumeTotalBytes - storageSummary.volumeAvailableBytes) }}</span>
        <span class="storage-dim"> / {{ formatBytes(storageSummary.volumeTotalBytes) }}</span>
        <span class="storage-dim"> ({{ formatBytes(storageSummary.volumeAvailableBytes) }} free)</span>
      </div>
    </div>
    <div class="storage-bar">
      <div class="storage-bar-vm" :style="{ width: Math.min(storageSummary.totalActualBytes / storageSummary.volumeTotalBytes * 100, 100) + '%' }" />
      <div class="storage-bar-other" :style="{ width: Math.min(((storageSummary.volumeTotalBytes - storageSummary.volumeAvailableBytes - storageSummary.totalActualBytes) / storageSummary.volumeTotalBytes) * 100, 100) + '%' }" />
    </div>
    <div class="storage-legend">
      <span><span class="legend-dot" style="background:var(--purple)"></span>VM disks</span>
      <span><span class="legend-dot" style="background:var(--text-dim)"></span>Other</span>
      <span><span class="legend-dot" style="background:rgba(255,255,255,0.06)"></span>Free</span>
    </div>
  </div>

  <EmptyState v-if="disks.length === 0" icon="disk" title="No disks. Disks are created automatically when you create a VM." />

  <DataTable v-else :columns="[
     { key: 'name', label: 'Name' },
     { key: 'format', label: 'Format' },
     { key: 'provisioned', label: 'Provisioned' },
     { key: 'used', label: 'Used on Disk' },
     { key: 'vm', label: 'VM' },
     { key: 'actions', label: '' },
   ]">
        <tr v-for="d in disks" :key="d.id">
          <td style="font-weight:500">{{ d.name }}</td>
          <td><span class="badge badge-gray">{{ d.format }}</span></td>
          <td class="mono">{{ formatBytes(d.sizeBytes) }}</td>
          <td class="mono">
            <template v-if="diskUsages[d.id]">
              {{ formatBytes(diskUsages[d.id].actualSizeBytes) }}
              <div class="usage-bar">
                <div class="usage-bar-fill" :style="{ width: Math.min(diskUsages[d.id].actualSizeBytes / diskUsages[d.id].virtualSizeBytes * 100, 100) + '%' }" />
              </div>
            </template>
            <span v-else style="color:var(--text-dim)">-</span>
          </td>
          <td>
            <a v-if="d.vmId" href="#" @click.prevent="router.push(`/vms/${d.vmId}`)" style="color:var(--accent);text-decoration:none">
              {{ vmStore.vms.find(v => v.id === d.vmId)?.name || d.vmId.slice(0,8) + '...' }}
            </a>
            <span v-else class="badge badge-gray">Unattached</span>
          </td>
          <td style="text-align:right">
            <div style="display:flex;gap:4px;justify-content:flex-end">
              <AppButton size="sm" @click="openResize(d)">Resize</AppButton>
              <AppButton v-if="!d.vmId" size="sm" @click="deleteDisk(d.id, d.name)">Delete</AppButton>
            </div>
          </td>
        </tr>
  </DataTable>

  <div v-if="showCreate" class="modal-overlay" @click.self="showCreate = false">
    <div class="modal">
      <h2>Create Disk</h2>
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

  <div v-if="resizingDisk" class="modal-overlay" @click.self="closeResize">
    <div class="modal" :style="resizeDone ? { maxWidth: '560px' } : {}">
      <h2>{{ resizeDone ? 'Disk Resized' : 'Resize Disk' }}</h2>

      <!-- Before resize -->
      <template v-if="!resizeDone">
        <p style="color:var(--text-secondary);font-size:13px;margin-bottom:16px">
          Resize <strong>{{ resizingDisk.name }}</strong> (currently {{ formatBytes(resizingDisk.sizeBytes) }}).
          Disks can only grow, not shrink.
        </p>
        <div class="form-group">
          <label>New Size (GB)</label>
          <input v-model.number="resizeSizeGB" type="number" :min="Math.ceil(resizingDisk.sizeBytes / (1024*1024*1024)) + 1" />
        </div>
        <FormError v-if="resizeError" :message="resizeError" />
        <div class="modal-actions">
          <AppButton @click="closeResize">Cancel</AppButton>
          <AppButton variant="primary" :disabled="resizeLoading" @click="resizeDisk">{{ resizeLoading ? 'Resizing...' : 'Resize' }}</AppButton>
        </div>
      </template>

      <!-- After resize: show guest commands -->
      <template v-else>
        <p style="color:var(--green);font-size:13px;margin-bottom:16px">
          The virtual disk has been resized. To use the new space, you need to grow the partition and filesystem inside the guest VM.
        </p>

        <div class="guest-cmds">
          <div v-for="cmd in guestResizeCommands" :key="cmd.id" class="guest-cmd-group">
            <button class="guest-cmd-header" @click="guestCmdsOpen = guestCmdsOpen === cmd.id ? null : cmd.id">
              <span>{{ cmd.label }}</span>
              <svg :class="{ rotated: guestCmdsOpen === cmd.id }" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>
            </button>
            <div v-if="guestCmdsOpen === cmd.id" class="guest-cmd-body">
              <pre><code>{{ cmd.commands }}</code></pre>
            </div>
          </div>
        </div>

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
.guest-cmds {
  display: flex;
  flex-direction: column;
  gap: 1px;
  background: var(--border);
  border: 1px solid var(--border);
  border-radius: var(--radius-xs);
  overflow: hidden;
}
.guest-cmd-group {
  background: var(--bg);
}
.guest-cmd-header {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 14px;
  font-size: 13px;
  font-weight: 600;
  color: var(--text-secondary);
  background: none;
  border: none;
  cursor: pointer;
  transition: background var(--transition);
}
.guest-cmd-header:hover {
  background: var(--bg-hover);
  color: var(--text);
}
.guest-cmd-header svg {
  transition: transform 0.2s ease;
  color: var(--text-dim);
}
.guest-cmd-header svg.rotated {
  transform: rotate(180deg);
}
.guest-cmd-body {
  padding: 0 14px 12px;
}
.guest-cmd-body pre {
  background: rgba(0,0,0,0.3);
  border-radius: var(--radius-xs);
  padding: 10px 14px;
  margin: 0;
  overflow-x: auto;
}
.guest-cmd-body code {
  font-family: var(--font-mono);
  font-size: 12px;
  line-height: 1.7;
  color: var(--green);
  white-space: pre;
}
</style>
