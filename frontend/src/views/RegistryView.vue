<script setup lang="ts">
import { ref, computed, reactive, onMounted, onUnmounted, watch } from 'vue'
import { useRouter } from 'vue-router'
import { useTemplateStore } from '../stores/templates'
import { useRepositoryStore } from '../stores/repositories'
import { useImageStore } from '../stores/images'
import { useToastStore } from '../stores/toast'
import TemplateDeployDrawer from '../components/TemplateDeployDrawer.vue'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import TabGroup from '../components/ui/TabGroup.vue'
import FormError from '../components/ui/FormError.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import AppModal from '../components/ui/AppModal.vue'
import ProgressBar from '../components/ui/ProgressBar.vue'
import { getWSTicket } from '../api/client'
import { formatBytes } from '../utils/format'
import type { VMTemplate, RepositoryImage, Image } from '../api/types'

const router = useRouter()
const templateStore = useTemplateStore()
const repoStore = useRepositoryStore()
const imageStore = useImageStore()
const toast = useToastStore()

// Tab
const activeTab = ref<'templates' | 'images'>('templates')

// Repos filtered by active tab
const templateRepos = computed(() =>
  repoStore.repositories.filter(r => r.repoType === 'templates')
)
const imageRepos = computed(() =>
  repoStore.repositories.filter(r => r.repoType === 'images')
)
const activeRepos = computed(() => activeTab.value === 'templates' ? templateRepos.value : imageRepos.value)

// Tab counts — independent of selectedRepoId so they stay stable when switching tabs
const templateTabCount = computed(() => {
  const repoIds = new Set(templateRepos.value.map(r => r.id))
  return templateStore.templates.filter(t => t.repositoryId && repoIds.has(t.repositoryId)).length
})
const imageTabCount = computed(() => {
  let count = 0
  for (const r of imageRepos.value) {
    const imgs = repoStore.imagesByRepo[r.id]
    if (imgs) count += imgs.filter(i => i.arch === 'arm64').length
  }
  return count
})

// Shared repo selection
const selectedRepoId = ref<string | null>(null)

// Auto-select "All" for both tabs
watch([activeTab, () => repoStore.repositories.length], () => {
  const repos = activeRepos.value
  if (selectedRepoId.value !== '__all__' && !repos.find(r => r.id === selectedRepoId.value)) {
    selectedRepoId.value = '__all__'
  }
}, { immediate: true })

// === Templates ===
const selectedTemplate = ref<VMTemplate | null>(null)
const activeCategory = ref('all')
const templateSearch = ref('')
const templatePage = ref(1)
const templatePerPage = 10

const categoryLabels: Record<string, string> = {
  'all': 'All',
  'general': 'General',
  'development': 'Development',
  'infrastructure': 'Infrastructure',
  'networking': 'Networking',
  'cloud-storage': 'Cloud & Storage',
  'home-automation': 'Home Automation',
}

const iconMap: Record<string, string> = {
  terminal: 'M4 17l6-6-6-6M12 19h8',
  code: 'M16 18l6-6-6-6M8 6l-6 6 6 6',
  container: 'M21 16V8a2 2 0 00-1-1.73l-7-4a2 2 0 00-2 0l-7 4A2 2 0 003 8v8a2 2 0 001 1.73l7 4a2 2 0 002 0l7-4A2 2 0 0021 16z',
  home: 'M3 9l9-7 9 7v11a2 2 0 01-2 2H5a2 2 0 01-2-2z M9 22V12h6v10',
  shield: 'M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z',
  cloud: 'M18 10h-1.26A8 8 0 109 20h9a5 5 0 000-10z',
}

const repoTemplates = computed(() => {
  if (selectedRepoId.value === '__all__') return templateStore.templates.filter(t => templateRepos.value.some(r => r.id === t.repositoryId))
  if (!selectedRepoId.value) return []
  return templateStore.templates.filter(t => t.repositoryId === selectedRepoId.value)
})

const availableCategories = computed(() => {
  const cats = new Set(repoTemplates.value.map(t => t.category))
  const specific = Object.keys(categoryLabels).filter(c => c !== 'all' && cats.has(c))
  return specific.length > 1 ? ['all', ...specific] : []
})

const filteredTemplates = computed(() => {
  let list = repoTemplates.value
  if (activeCategory.value !== 'all') {
    list = list.filter(t => t.category === activeCategory.value)
  }
  if (templateSearch.value) {
    const q = templateSearch.value.toLowerCase()
    list = list.filter(t => t.name.toLowerCase().includes(q) || (t.description || '').toLowerCase().includes(q))
  }
  return list
})

const templateTotalPages = computed(() => Math.max(1, Math.ceil(filteredTemplates.value.length / templatePerPage)))

const paginatedTemplates = computed(() => {
  const start = (templatePage.value - 1) * templatePerPage
  return filteredTemplates.value.slice(start, start + templatePerPage)
})

const categoryTabs = computed(() =>
  availableCategories.value.map(cat => ({
    key: cat,
    label: categoryLabels[cat] || cat,
  }))
)

function setCategory(cat: string) {
  activeCategory.value = cat
  templatePage.value = 1
}

watch(selectedRepoId, () => {
  activeCategory.value = 'all'
  templateSearch.value = ''
  templatePage.value = 1
})

watch(templateSearch, () => { templatePage.value = 1 })

function onDeployed() {
  selectedTemplate.value = null
  router.push('/vms')
}

// === Repositories / Images ===
const dlProgress = reactive<Record<string, { percent: number; bytesReceived: number; totalBytes: number | null; status?: string }>>({})
const eventSources: Record<string, EventSource> = {}
let pollTimer: number

const showRepoSettings = ref(false)
const showAddRepo = ref(false)
const newUrl = ref('')
const newRepoType = ref<'images' | 'templates'>('images')
const addError = ref('')
const addLoading = ref(false)

const repoImages = ref<RepositoryImage[]>([])
const imagesLoading = ref(false)
const filterType = ref('')
const searchQuery = ref('')
const downloading = ref<Set<string>>(new Set())
const imagePage = ref(1)
const imagePerPage = 10

const confirmDeleteLocal = ref<RepositoryImage | null>(null)
const confirmDeleteRepo = ref<{ id: string; name: string } | null>(null)
const deletingLocal = ref(false)
const deletingRepo = ref(false)

onMounted(async () => {
  await Promise.all([templateStore.fetchAll(), repoStore.fetchAll(), imageStore.fetchAll()])
  // Eagerly fetch images for all image repos so the tab count is available
  for (const r of imageRepos.value) {
    repoStore.fetchImages(r.id)
  }
  subscribeDownloading()
  pollTimer = window.setInterval(() => {
    if (imageStore.images.some(i => i.status === 'downloading' || i.status === 'decompressing')) {
      imageStore.fetchAll()
    }
  }, 5000)
})

onUnmounted(() => {
  clearInterval(pollTimer)
  Object.values(eventSources).forEach(es => es.close())
})

async function subscribeDownloading() {
  for (const img of imageStore.images) {
    if ((img.status === 'downloading' || img.status === 'decompressing') && !eventSources[img.id]) {
      let ticket: string
      try {
        ticket = await getWSTicket()
      } catch { continue }
      const es = new EventSource(`/api/images/${img.id}/progress?ticket=${ticket}`)
      es.onmessage = (e) => {
        const data = JSON.parse(e.data)
        dlProgress[img.id] = {
          percent: data.percent ?? 0,
          bytesReceived: data.bytesReceived,
          totalBytes: data.totalBytes,
          status: data.status,
        }
        if (data.status === 'ready' || data.status === 'error') {
          es.close()
          delete eventSources[img.id]
          delete dlProgress[img.id]
          imageStore.fetchAll()
        }
      }
      es.onerror = () => { es.close(); delete eventSources[img.id] }
      eventSources[img.id] = es
    }
  }
}

function localImageProgress(img: RepositoryImage) {
  const local = localImage(img)
  return local ? dlProgress[local.id] : undefined
}

async function loadRepoImages() {
  const id = selectedRepoId.value
  if (!id) return
  imagesLoading.value = true
  try {
    if (id === '__all__') {
      const results = await Promise.all(imageRepos.value.map(r => repoStore.fetchImages(r.id)))
      repoImages.value = results.flat()
    } else {
      repoImages.value = await repoStore.fetchImages(id)
    }
  } finally {
    imagesLoading.value = false
  }
  imagePage.value = 1
}

watch(selectedRepoId, loadRepoImages)
watch(activeTab, (tab) => {
  if (tab === 'images' && repoImages.value.length === 0) loadRepoImages()
})

const filteredImages = computed(() => {
  return repoImages.value.filter(img => {
    if (img.arch !== 'arm64') return false
    if (filterType.value && img.imageType !== filterType.value) return false
    if (searchQuery.value) {
      const q = searchQuery.value.toLowerCase()
      if (!img.name.toLowerCase().includes(q) && !(img.description || '').toLowerCase().includes(q)) return false
    }
    return true
  })
})

const imageTotalPages = computed(() => Math.ceil(filteredImages.value.length / imagePerPage))
const paginatedImages = computed(() => {
  const start = (imagePage.value - 1) * imagePerPage
  return filteredImages.value.slice(start, start + imagePerPage)
})

const types = computed(() => [...new Set(repoImages.value.map(i => i.imageType))])

watch([filterType, searchQuery], () => { imagePage.value = 1 })

function localImage(img: RepositoryImage): Image | undefined {
  return imageStore.images.find(i => i.sourceUrl === img.downloadUrl)
}

function deleteLocal(img: RepositoryImage) {
  confirmDeleteLocal.value = img
}

async function doDeleteLocal() {
  if (!confirmDeleteLocal.value) return
  const img = confirmDeleteLocal.value
  const local = localImage(img)
  if (!local) { confirmDeleteLocal.value = null; return }
  deletingLocal.value = true
  try {
    await Promise.all([imageStore.remove(local.id), new Promise(r => setTimeout(r, 400))])
    toast.success(`Deleted "${img.name}"`)
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    deletingLocal.value = false
    confirmDeleteLocal.value = null
  }
}

async function download(img: RepositoryImage) {
  downloading.value.add(img.id)
  try {
    await repoStore.downloadImage(img.id)
    await imageStore.fetchAll()
    setTimeout(subscribeDownloading, 500)
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    downloading.value.delete(img.id)
  }
}

async function cancelDownload(img: RepositoryImage) {
  const local = localImage(img)
  if (!local) return
  if (eventSources[local.id]) {
    eventSources[local.id].close()
    delete eventSources[local.id]
  }
  delete dlProgress[local.id]
  try {
    await imageStore.remove(local.id)
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  }
}

async function syncRepo(id: string) {
  try {
    await repoStore.sync(id)
    if (selectedRepoId.value === id) {
      repoImages.value = await repoStore.fetchImages(id)
    }
    await templateStore.fetchAll()
    // Only show success if sync didn't end in error
    const repo = repoStore.repositories.find(r => r.id === id)
    if (repo && repo.syncStatus !== 'error') {
      toast.success('Repository synced')
    }
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
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
    await Promise.all([repoStore.remove(id), new Promise(r => setTimeout(r, 400))])
    if (selectedRepoId.value === id) {
      selectedRepoId.value = repoStore.repositories.length > 0 ? repoStore.repositories[0].id : null
      repoImages.value = []
    }
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    deletingRepo.value = false
    confirmDeleteRepo.value = null
  }
}

async function addRepo() {
  addError.value = ''
  if (!newUrl.value.trim()) { addError.value = 'URL required'; return }
  addLoading.value = true
  try {
    await repoStore.add(newUrl.value.trim(), newRepoType.value)
    showAddRepo.value = false
    newUrl.value = ''
    toast.success('Repository added')
  } catch (e: any) {
    addError.value = e.response?.data?.reason || e.message
  } finally {
    addLoading.value = false
  }
}
</script>

<template>
  <div class="page-header">
    <h1>Repositories</h1>
    <AppButton icon="settings" @click="showRepoSettings = true">Manage</AppButton>
  </div>

  <!-- Manage Repositories Modal -->
  <AppModal v-if="showRepoSettings" title="Manage Repositories" max-width="640px" @close="showRepoSettings = false">
    <div v-for="r in repoStore.repositories" :key="r.id" class="repo-item">
      <div style="flex:1;min-width:0">
        <div style="font-weight:500;font-size:13px;display:flex;align-items:center;gap:6px;flex-wrap:wrap">
          {{ r.name }}
          <span class="badge badge-gray" style="font-size:10px">{{ r.repoType }}</span>
          <span v-if="r.isBuiltIn" class="badge badge-accent" style="font-size:10px">built-in</span>
          <span v-if="r.syncStatus === 'syncing'" class="badge badge-amber" style="font-size:10px">syncing...</span>
          <span v-else-if="r.syncStatus === 'error' || r.lastError" class="badge badge-red" style="font-size:10px">error</span>
          <span v-else-if="r.lastSyncedAt" class="badge badge-green" style="font-size:10px">synced</span>
        </div>
        <div style="font-size:11px;color:var(--text-dim);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-top:2px">{{ r.url }}</div>
      </div>
      <div style="display:flex;gap:4px;flex-shrink:0">
        <AppButton size="sm" :disabled="r.syncStatus === 'syncing'" @click="syncRepo(r.id)">{{ r.syncStatus === 'syncing' ? 'Syncing...' : 'Sync' }}</AppButton>
        <AppButton v-if="!r.isBuiltIn" variant="danger" size="sm" @click="deleteRepo(r.id, r.name)">Remove</AppButton>
      </div>
    </div>
    <div v-if="repoStore.repositories.length === 0" style="padding:16px;text-align:center;color:var(--text-dim);font-size:13px">
      No repositories configured.
    </div>
    <template #actions>
      <AppButton icon="plus" @click="newRepoType = activeTab === 'templates' ? 'templates' : 'images'; showAddRepo = true; showRepoSettings = false">Add Repository</AppButton>
      <div style="flex:1" />
      <AppButton @click="showRepoSettings = false">Close</AppButton>
    </template>
  </AppModal>

  <!-- Tabs -->
  <TabGroup
    v-model="activeTab"
    :tabs="[
      { key: 'templates', label: 'Templates', count: templateTabCount },
      { key: 'images', label: 'Images', count: imageTabCount },
    ]"
    style="margin-bottom:16px"
  />

  <!-- ==================== Templates Tab ==================== -->
  <template v-if="activeTab === 'templates'">
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px;flex-wrap:wrap">
      <AppSelect v-if="activeRepos.length > 1" v-model="selectedRepoId" size="sm">
        <option value="__all__">All Repos</option>
        <option v-for="r in activeRepos" :key="r.id" :value="r.id">{{ r.name }}</option>
      </AppSelect>
      <input v-model="templateSearch" placeholder="Search templates..." style="flex:1;min-width:200px;font-size:13px;padding:7px 12px" />
      <TabGroup v-if="categoryTabs.length > 0" :model-value="activeCategory" :tabs="categoryTabs" @update:model-value="setCategory" />
      <span style="font-size:12px;color:var(--text-dim)">{{ filteredTemplates.length }} templates</span>
    </div>

    <EmptyState v-if="templateStore.loading" title="Loading templates..." />

    <EmptyState v-else-if="filteredTemplates.length === 0" title="No templates in this category" />

    <DataTable v-else :columns="[
      { key: 'icon', label: '', width: '40px' },
      { key: 'name', label: 'Name' },
      { key: 'category', label: 'Category' },
      { key: 'resources', label: 'Resources' },
      { key: 'disk', label: 'Disk' },
      { key: 'actions', label: '', align: 'right' },
    ]">
      <tr v-for="t in paginatedTemplates" :key="t.id" class="tmpl-row" @click="selectedTemplate = t">
        <td>
          <div class="tmpl-icon">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none"
              stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
              <path :d="iconMap[t.icon] || iconMap.terminal" />
            </svg>
          </div>
        </td>
        <td>
          <div style="font-weight:500">{{ t.name }}</div>
          <div style="font-size:12px;color:var(--text-dim);margin-top:2px;max-width:320px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{{ t.description }}</div>
        </td>
        <td><span class="badge badge-gray">{{ categoryLabels[t.category] || t.category }}</span></td>
        <td>
          <span style="font-size:12px;color:var(--text-secondary)">{{ t.cpuCount }} CPU &middot; {{ t.memoryMB >= 1024 ? (t.memoryMB / 1024).toFixed(t.memoryMB % 1024 === 0 ? 0 : 1) + ' GB' : t.memoryMB + ' MB' }}</span>
        </td>
        <td><span style="font-size:12px;color:var(--text-secondary)">{{ t.diskSizeGB }} GB</span></td>
        <td style="text-align:right">
          <AppButton variant="primary" size="sm" @click.stop="selectedTemplate = t">Deploy</AppButton>
        </td>
      </tr>
    </DataTable>

    <div v-if="templateTotalPages > 1" class="pagination">
      <AppButton size="sm" icon="chevron-left" :disabled="templatePage <= 1" @click="templatePage--" />
      <span class="page-info">{{ templatePage }} / {{ templateTotalPages }}</span>
      <AppButton size="sm" icon="chevron-right" :disabled="templatePage >= templateTotalPages" @click="templatePage++" />
    </div>

    <TemplateDeployDrawer
      v-if="selectedTemplate"
      :template="selectedTemplate"
      @close="selectedTemplate = null"
      @deployed="onDeployed"
    />
  </template>

  <!-- ==================== Images Tab ==================== -->
  <template v-if="activeTab === 'images'">
    <!-- Filters -->
    <div v-if="repoImages.length > 0 || activeRepos.length > 1" style="display:flex;align-items:center;gap:12px;margin-bottom:16px;flex-wrap:wrap">
      <AppSelect v-if="activeRepos.length > 1" v-model="selectedRepoId" size="sm">
        <option value="__all__">All Repos</option>
        <option v-for="r in activeRepos" :key="r.id" :value="r.id">{{ r.name }}</option>
      </AppSelect>
      <input v-model="searchQuery" placeholder="Search images..." style="flex:1;min-width:200px;font-size:13px;padding:7px 12px" />
      <AppSelect v-model="filterType" size="sm">
        <option value="">All types</option>
        <option v-for="t in types" :key="t" :value="t">{{ t }}</option>
      </AppSelect>
      <span style="font-size:12px;color:var(--text-dim)">{{ filteredImages.length }} images</span>
    </div>

    <EmptyState v-if="imagesLoading" title="Loading catalog..." style="padding:48px" />
    <EmptyState v-else-if="!selectedRepoId" title="No repository selected" subtitle="Add one via the Manage button." style="padding:48px" />
    <EmptyState v-else-if="filteredImages.length === 0" :title="repoImages.length === 0 ? 'Repository is empty' : 'No images match the current filters'" :subtitle="repoImages.length === 0 ? 'Click Manage > Sync to fetch the catalog.' : undefined" style="padding:48px" />
    <div v-else>
      <DataTable :columns="[
        { key: 'name', label: 'Name' },
        { key: 'type', label: 'Type' },
        { key: 'arch', label: 'Arch' },
        { key: 'version', label: 'Version' },
        { key: 'size', label: 'Size' },
        { key: 'status', label: 'Status' },
        { key: 'actions', label: '' },
      ]">
            <tr v-for="img in paginatedImages" :key="img.id">
              <td>
                <div style="font-weight:500">{{ img.name }}</div>
                <div v-if="img.description && !localImageProgress(img) && !downloading.has(img.id)" style="font-size:12px;color:var(--text-dim);margin-top:2px">{{ img.description }}</div>
                <ProgressBar v-if="downloading.has(img.id) && !localImageProgress(img)" indeterminate style="margin-top:6px">Starting download...</ProgressBar>
                <ProgressBar v-else-if="localImageProgress(img)" :percent="localImageProgress(img)!.percent ?? 0" style="margin-top:6px">
                  <template v-if="localImageProgress(img)!.status === 'decompressing'">Decompressing...</template>
                  <template v-else>
                    {{ localImageProgress(img)!.percent }}% &middot;
                    {{ formatBytes(localImageProgress(img)!.bytesReceived) }}
                    <template v-if="localImageProgress(img)!.totalBytes"> / {{ formatBytes(localImageProgress(img)!.totalBytes) }}</template>
                  </template>
                </ProgressBar>
              </td>
              <td><span class="badge" :class="img.imageType === 'iso' ? 'badge-blue' : 'badge-purple'">{{ img.imageType }}</span></td>
              <td><span class="badge badge-gray">{{ img.arch }}</span></td>
              <td class="mono" style="color:var(--text-secondary)">{{ img.version || '-' }}</td>
              <td class="mono" style="color:var(--text-secondary)">{{ formatBytes(img.sizeBytes) }}</td>
              <td>
                <template v-if="localImage(img)">
                  <span class="status-pill" :class="localImage(img)!.status === 'ready' ? 'running' : localImage(img)!.status === 'error' ? 'error' : 'starting'">
                    {{ localImage(img)!.status }}
                  </span>
                </template>
                <span v-else style="color:var(--text-dim);font-size:12px">-</span>
              </td>
              <td>
                <div style="display:flex;gap:6px;justify-content:flex-end">
                  <template v-if="localImage(img)">
                    <template v-if="localImage(img)!.status === 'downloading' || localImage(img)!.status === 'decompressing'">
                      <AppButton variant="danger" size="sm" @click="cancelDownload(img)">Cancel</AppButton>
                    </template>
                    <template v-else>
                      <AppButton variant="danger" size="sm" @click="deleteLocal(img)">Delete</AppButton>
                      <AppButton v-if="localImage(img)!.status === 'error'" variant="primary" size="sm" :disabled="downloading.has(img.id)" @click="download(img)">
                        Retry
                      </AppButton>
                    </template>
                  </template>
                  <AppButton v-else variant="primary" size="sm" :disabled="downloading.has(img.id)" @click="download(img)">
                    {{ downloading.has(img.id) ? 'Starting...' : 'Download' }}
                  </AppButton>
                </div>
              </td>
            </tr>
      </DataTable>

      <div v-if="imageTotalPages > 1" class="pagination">
        <AppButton size="sm" :disabled="imagePage <= 1" @click="imagePage--">Previous</AppButton>
        <div class="pagination-pages">
          <button v-for="p in imageTotalPages" :key="p"
            class="pagination-page" :class="{ active: p === imagePage }"
            @click="imagePage = p">{{ p }}</button>
        </div>
        <AppButton size="sm" :disabled="imagePage >= imageTotalPages" @click="imagePage++">Next</AppButton>
      </div>
    </div>

  </template>

  <!-- Add Repo Modal -->
  <AppModal v-if="showAddRepo" title="Add Repository" @close="showAddRepo = false">
    <div class="form-group">
      <label>Type</label>
      <div class="type-toggle">
        <button :class="{ active: newRepoType === 'images' }" @click="newRepoType = 'images'">Images</button>
        <button :class="{ active: newRepoType === 'templates' }" @click="newRepoType = 'templates'">Templates</button>
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
    v-if="confirmDeleteLocal"
    title="Delete Downloaded Image"
    :message="`Delete the local copy of &quot;${confirmDeleteLocal.name}&quot;?`"
    confirm-label="Delete"
    :danger="true"
    :loading="deletingLocal"
    @confirm="doDeleteLocal"
    @cancel="confirmDeleteLocal = null"
  />

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
  transition: all 0.15s;
}
.type-toggle button:not(:last-child) {
  border-right: 1px solid var(--border);
}
.type-toggle button.active {
  background: var(--accent);
  color: #fff;
}
.tmpl-row {
  cursor: pointer;
}
.tmpl-row:hover {
  background: var(--bg-hover);
}
.tmpl-icon {
  width: 32px;
  height: 32px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: var(--bg-hover);
  border-radius: var(--radius);
  color: var(--primary);
}
.pagination {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 12px;
  margin-top: 16px;
}
.page-info {
  font-size: 12px;
  color: var(--text-dim);
  font-variant-numeric: tabular-nums;
}
.pagination-pages {
  display: flex;
  gap: 4px;
}
.pagination-page {
  width: 32px;
  height: 32px;
  border-radius: var(--radius-sm);
  border: 1px solid var(--border);
  background: transparent;
  color: var(--text-secondary);
  font-size: 13px;
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
}
.pagination-page:hover { background: var(--bg-hover); }
.pagination-page.active {
  background: var(--accent);
  color: #fff;
  border-color: var(--accent);
}
.repo-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 12px 0;
  border-bottom: 1px solid var(--border-subtle);
}
.repo-item:last-child { border-bottom: none; }
</style>
