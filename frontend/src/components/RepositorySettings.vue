<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { apiErrorMessage } from '../api/errors'
import { useDevicesStore } from '../stores/devices'
import { useRepositoryStore } from '../stores/repositories'
import { useToastStore } from '../stores/toast'
import {
  catalogDeviceHasError,
  catalogHasDeviceError,
  catalogIsSyncing,
  lastSyncedLabel,
  syncStatusBadge,
  syncStatusLabel,
} from '../utils/repositoryCatalog'
import AppButton from './ui/AppButton.vue'
import AppModal from './ui/AppModal.vue'
import ConfirmDialog from './ConfirmDialog.vue'
import DataTable from './ui/DataTable.vue'
import EmptyState from './ui/EmptyState.vue'
import FormError from './ui/FormError.vue'

const repoStore = useRepositoryStore()
const devicesStore = useDevicesStore()
const toast = useToastStore()

const showAddRepo = ref(false)
const newUrl = ref('')
const newRepoType = ref<'images' | 'templates'>('images')
const addError = ref('')
const addLoading = ref(false)
const confirmDeleteRepo = ref<{ id: string; name: string } | null>(null)
const deletingRepo = ref(false)

onMounted(async () => {
  await devicesStore.fetchHealth()
  await repoStore.fetchAll()
})

async function syncRepo(id: string) {
  try {
    await repoStore.sync(id)
    const repo = repoStore.repositories.find((r) => r.id === id)
    if (repo && catalogHasDeviceError(repo)) {
      const failed = repo.deviceSyncs.find((row) => catalogDeviceHasError(row))
      toast.error(failed?.lastError || repo.lastError || 'Sync failed on a Device')
      return
    }
    toast.success('Repository synced')
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  }
}

function deleteRepo(id: string, name: string) {
  confirmDeleteRepo.value = { id, name }
}

async function doDeleteRepo() {
  if (!confirmDeleteRepo.value) return
  const { id } = confirmDeleteRepo.value
  deletingRepo.value = true
  try {
    await repoStore.remove(id)
  } catch (e: unknown) {
    toast.error(apiErrorMessage(e))
  } finally {
    deletingRepo.value = false
    confirmDeleteRepo.value = null
  }
}

function openAdd() {
  addError.value = ''
  newUrl.value = ''
  newRepoType.value = 'images'
  showAddRepo.value = true
}

async function addRepo() {
  addError.value = ''
  if (!newUrl.value.trim()) {
    addError.value = 'URL required'
    return
  }
  addLoading.value = true
  try {
    await repoStore.add(newUrl.value.trim(), newRepoType.value)
    showAddRepo.value = false
    newUrl.value = ''
    toast.success('Repository added')
  } catch (e: unknown) {
    addError.value = apiErrorMessage(e)
  } finally {
    addLoading.value = false
  }
}
</script>

<template>
  <p style="color:var(--text-secondary);font-size:13px;margin:0 0 16px 0;max-width:640px">
    Catalog URLs each Device in this Home syncs. Member catalog errors show here, not only when Create VM fails.
  </p>
  <div style="margin-bottom:16px">
    <AppButton variant="primary" @click="openAdd">Add repository</AppButton>
  </div>
  <EmptyState v-if="repoStore.loading" title="Loading repositories..." />
  <EmptyState
    v-else-if="repoStore.error"
    title="Could not load repositories"
    :subtitle="repoStore.error"
  />
  <EmptyState
    v-else-if="repoStore.repositories.length === 0"
    title="No repositories configured"
    subtitle="Add a catalog URL to sync templates and images."
  />
  <DataTable
    v-else
    :columns="[
      { key: 'name', label: 'Name' },
      { key: 'type', label: 'Type' },
      { key: 'url', label: 'URL' },
      { key: 'status', label: 'Status' },
      { key: 'actions', label: '', align: 'right' },
    ]"
  >
    <tr v-for="r in repoStore.repositories" :key="r.id">
      <td>
        <div style="font-weight:500;display:flex;align-items:center;gap:6px;flex-wrap:wrap">
          <span>{{ r.name }}</span>
          <span v-if="r.isBuiltIn" class="badge badge-accent" style="font-size:10px">built-in</span>
        </div>
        <div
          v-if="!r.isBuiltIn && r.lastError"
          style="font-size:12px;color:var(--red, #ef4444);margin-top:2px"
        >{{ r.lastError }}</div>
      </td>
      <td><span class="badge badge-gray">{{ r.repoType }}</span></td>
      <td>
        <span class="mono" style="color:var(--text-secondary);font-size:12px;word-break:break-all">{{ r.url }}</span>
      </td>
      <td>
        <div
          v-if="r.deviceSyncs.length"
          style="display:flex;flex-direction:column;gap:8px"
        >
          <div v-for="d in r.deviceSyncs" :key="d.hostId">
            <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap">
              <span style="font-size:12px">{{ d.label }}</span>
              <span
                class="badge"
                :class="syncStatusBadge(d.syncStatus, d.lastError, d.lastSyncedAt)"
                style="font-size:10px"
              >{{ syncStatusLabel(d.syncStatus, d.lastError, d.lastSyncedAt) }}</span>
            </div>
            <div style="font-size:12px;color:var(--text-secondary);margin-top:2px">
              Last synced {{ lastSyncedLabel(d.lastSyncedAt) }}
            </div>
            <div
              v-if="d.lastError"
              style="font-size:12px;color:var(--red, #ef4444);margin-top:2px"
            >{{ d.lastError }}</div>
          </div>
        </div>
        <div v-else>
          <span
            class="badge"
            :class="syncStatusBadge(r.syncStatus, r.lastError, r.lastSyncedAt)"
            style="font-size:10px"
          >{{ syncStatusLabel(r.syncStatus, r.lastError, r.lastSyncedAt) }}</span>
          <div style="font-size:12px;color:var(--text-secondary);margin-top:2px">
            Last synced {{ lastSyncedLabel(r.lastSyncedAt) }}
          </div>
        </div>
      </td>
      <td style="text-align:right">
        <div style="display:flex;gap:6px;justify-content:flex-end">
          <AppButton size="sm" :disabled="catalogIsSyncing(r)" @click="syncRepo(r.id)">
            {{ catalogIsSyncing(r) ? 'Syncing...' : 'Sync' }}
          </AppButton>
          <AppButton v-if="!r.isBuiltIn" variant="danger" size="sm" @click="deleteRepo(r.id, r.name)">Remove</AppButton>
        </div>
      </td>
    </tr>
  </DataTable>

  <AppModal
    v-if="showAddRepo"
    title="Add Repository"
    subtitle="A catalog URL Devices in this Home can sync."
    rail-title="Source"
    @close="showAddRepo = false"
  >
    <template #rail>
      <div class="split-s on">
        <span class="wizard-dot active">1</span>
        <div><div class="t">Kind</div><div class="d">Templates / images</div></div>
      </div>
      <div class="split-s">
        <span class="wizard-dot">2</span>
        <div><div class="t">URL</div><div class="d">Catalog JSON</div></div>
      </div>
    </template>
    <div class="form-group">
      <label>Type</label>
      <div class="type-toggle">
        <button type="button" :class="{ active: newRepoType === 'images' }" @click="newRepoType = 'images'">Images</button>
        <button type="button" :class="{ active: newRepoType === 'templates' }" @click="newRepoType = 'templates'">Templates</button>
      </div>
    </div>
    <div class="form-group">
      <label>Catalog URL</label>
      <input v-model="newUrl" placeholder="https://example.com/catalog.json" />
    </div>
    <FormError v-if="addError" :message="addError" />
    <template #actions>
      <AppButton @click="showAddRepo = false">Cancel</AppButton>
      <AppButton variant="primary" :loading="addLoading" loading-text="Adding..." @click="addRepo">Add</AppButton>
    </template>
  </AppModal>

  <ConfirmDialog
    v-if="confirmDeleteRepo"
    title="Remove Repository"
    :message="`Remove repository &quot;${confirmDeleteRepo.name}&quot;? This will also remove all its cached image entries.`"
    confirm-label="Remove"
    :danger="true"
    :loading="deletingRepo"
    @confirm="doDeleteRepo"
    @cancel="confirmDeleteRepo = null"
  />
</template>

<style scoped>
.type-toggle {
  display: inline-flex;
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  overflow: hidden;
}
.type-toggle button {
  padding: 6px 14px;
  font-size: 12px;
  font-weight: 500;
  background: transparent;
  border: none;
  color: var(--text-secondary);
  cursor: pointer;
}
.type-toggle button:not(:last-child) {
  border-right: 1px solid var(--border);
}
.type-toggle button.active {
  background: var(--accent);
  color: #fff;
}
</style>
