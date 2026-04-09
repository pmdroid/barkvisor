<script setup lang="ts">
import { onMounted, onUnmounted, ref, reactive } from 'vue'
import { useImageStore } from '../stores/images'
import { getWSTicket } from '../api/client'
import * as tus from 'tus-js-client'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import FormError from '../components/ui/FormError.vue'
import ProgressBar from '../components/ui/ProgressBar.vue'
import { formatBytes } from '../utils/format'

const store = useImageStore()
const showDownload = ref(false)
const dlName = ref('')
const dlUrl = ref('')
const dlType = ref<'iso' | 'cloud-image'>('iso')
const dlArch = ref<'arm64'>('arm64')
const dlLoading = ref(false)
const dlError = ref('')

// Upload state
const showUpload = ref(false)
const uploadName = ref('')
const uploadType = ref<'iso' | 'cloud-image'>('iso')
const uploadArch = ref<'arm64'>('arm64')
const uploadFile = ref<File | null>(null)
const uploadError = ref('')
const uploadProgress = ref(0)
const uploading = ref(false)
const fileInputRef = ref<HTMLInputElement>()
let currentUpload: tus.Upload | null = null

// Download progress tracking via SSE
const downloadProgress = reactive<Record<string, { percent: number; bytesReceived: number; totalBytes: number | null; status: string }>>({})
const eventSources: Record<string, EventSource> = {}

async function subscribeDownloading() {
  for (const img of store.images) {
    if ((img.status === 'downloading' || img.status === 'decompressing') && !eventSources[img.id]) {
      let ticket: string
      try { ticket = await getWSTicket() } catch { continue }
      const es = new EventSource(`/api/images/${img.id}/progress?ticket=${ticket}`)
      es.onmessage = (e) => {
        const data = JSON.parse(e.data)
        downloadProgress[img.id] = {
          percent: data.percent ?? 0,
          bytesReceived: data.bytesReceived,
          totalBytes: data.totalBytes,
          status: data.status,
        }
        if (data.status === 'ready' || data.status === 'error') {
          es.close()
          delete eventSources[img.id]
          delete downloadProgress[img.id]
          store.fetchAll()
        }
      }
      es.onerror = () => { es.close(); delete eventSources[img.id] }
      eventSources[img.id] = es
    }
  }
}

let pollTimer: number

onMounted(async () => {
  await store.fetchAll()
  subscribeDownloading()
  pollTimer = window.setInterval(() => {
    if (store.images.some(i => i.status === 'downloading' || i.status === 'uploading' || i.status === 'decompressing')) {
      store.fetchAll().then(() => subscribeDownloading())
    }
  }, 5000)
})

onUnmounted(() => {
  clearInterval(pollTimer)
  Object.values(eventSources).forEach(es => es.close())
})

async function startDownload() {
  dlError.value = ''
  if (!dlName.value.trim() || !dlUrl.value.trim()) { dlError.value = 'Name and URL required'; return }
  dlLoading.value = true
  try {
    await store.startDownload({
      name: dlName.value.trim(),
      url: dlUrl.value.trim(),
      imageType: dlType.value,
      arch: dlArch.value,
    })
    showDownload.value = false
    dlName.value = ''; dlUrl.value = ''
    await store.fetchAll()
    setTimeout(subscribeDownloading, 500)
  } catch (e: any) {
    dlError.value = e.response?.data?.reason || e.message
  } finally {
    dlLoading.value = false
  }
}

function onFileSelect(e: Event) {
  const input = e.target as HTMLInputElement
  if (input.files?.length) {
    uploadFile.value = input.files[0]
    if (!uploadName.value) {
      uploadName.value = input.files[0].name.replace(/\.\w+$/, '')
    }
    // Auto-detect type from extension
    const name = input.files[0].name.toLowerCase()
    if (name.endsWith('.iso')) {
      uploadType.value = 'iso'
    } else {
      uploadType.value = 'cloud-image'
    }
  }
}

function startUpload() {
  uploadError.value = ''
  if (!uploadFile.value) { uploadError.value = 'Select a file'; return }
  if (!uploadName.value.trim()) { uploadError.value = 'Name required'; return }

  const token = localStorage.getItem('token')
  uploading.value = true
  uploadProgress.value = 0

  const upload = new tus.Upload(uploadFile.value, {
    endpoint: '/api/images/tus',
    retryDelays: [0, 1000, 3000, 5000],
    chunkSize: 5 * 1024 * 1024, // 5 MB chunks
    metadata: {
      name: uploadName.value.trim(),
      imageType: uploadType.value,
      arch: uploadArch.value,
    },
    headers: {
      'Authorization': `Bearer ${token}`,
    },
    onError(error: any) {
      uploadError.value = error.message || 'Upload failed'
      uploading.value = false
    },
    onProgress(bytesUploaded: number, bytesTotal: number) {
      uploadProgress.value = Math.round((bytesUploaded / bytesTotal) * 100)
    },
    onSuccess() {
      uploading.value = false
      showUpload.value = false
      uploadFile.value = null
      uploadName.value = ''
      uploadProgress.value = 0
      if (fileInputRef.value) fileInputRef.value.value = ''
      store.fetchAll()
    },
  })

  currentUpload = upload
  upload.start()
}

function cancelUpload() {
  if (currentUpload) {
    currentUpload.abort()
    currentUpload = null
  }
  uploading.value = false
  uploadProgress.value = 0
}

const confirmTarget = ref<{ id: string; name: string } | null>(null)
const deleting = ref(false)

async function deleteImage(id: string, name: string) {
  confirmTarget.value = { id, name }
}

async function doDeleteImage() {
  if (!confirmTarget.value) return
  const { id } = confirmTarget.value
  deleting.value = true
  try {
    await Promise.all([
      store.remove(id),
      new Promise(r => setTimeout(r, 400))
    ])
  } finally {
    deleting.value = false
    confirmTarget.value = null
  }
}

</script>

<template>
  <div class="page-header">
    <h1>Images</h1>
    <div style="display:flex;gap:8px">
      <AppButton icon="upload" @click="showUpload = true">Upload Image</AppButton>
      <AppButton variant="primary" icon="download" @click="showDownload = true">Download Image</AppButton>
    </div>
  </div>

  <EmptyState v-if="store.images.length === 0 && !store.loading" icon="image" title="No images yet" subtitle="Upload an ISO/disk image or download one from a URL" />

  <DataTable v-else :columns="[{ key: 'name', label: 'Name' }, { key: 'type', label: 'Type' }, { key: 'arch', label: 'Arch' }, { key: 'size', label: 'Size' }, { key: 'status', label: 'Status' }, { key: 'actions', label: '' }]">
        <tr v-for="img in store.images" :key="img.id">
          <td>
            <div style="font-weight:500">{{ img.name }}</div>
            <ProgressBar v-if="downloadProgress[img.id]" :percent="downloadProgress[img.id].percent ?? 0" style="margin-top:4px">
              <template v-if="downloadProgress[img.id].status === 'decompressing'">Decompressing...</template>
              <template v-else>
                {{ downloadProgress[img.id].percent }}% &middot;
                {{ formatBytes(downloadProgress[img.id].bytesReceived) }}
                <template v-if="downloadProgress[img.id].totalBytes"> / {{ formatBytes(downloadProgress[img.id].totalBytes) }}</template>
              </template>
            </ProgressBar>
          </td>
          <td><span class="badge" :class="img.imageType === 'iso' ? 'badge-blue' : 'badge-purple'">{{ img.imageType }}</span></td>
          <td><span class="badge badge-gray">{{ img.arch }}</span></td>
          <td class="mono">{{ formatBytes(img.sizeBytes) }}</td>
          <td>
            <span class="status-pill" :class="img.status === 'ready' ? 'running' : img.status === 'error' ? 'error' : 'starting'">
              {{ img.status }}
            </span>
          </td>
          <td style="text-align:right"><AppButton size="sm" @click="deleteImage(img.id, img.name)">Delete</AppButton></td>
        </tr>
  </DataTable>

  <!-- Upload Modal -->
  <div v-if="showUpload" class="modal-overlay" @click.self="!uploading && (showUpload = false)">
    <div class="modal">
      <h2>Upload Image</h2>
      <div class="form-group">
        <label>File</label>
        <div class="file-drop" @click="fileInputRef?.click()" @dragover.prevent @drop.prevent="(e: DragEvent) => { if (e.dataTransfer?.files.length) { uploadFile = e.dataTransfer.files[0]; if (!uploadName) uploadName = uploadFile.name.replace(/\.\w+$/, '') } }">
          <input ref="fileInputRef" type="file" accept=".iso,.img,.qcow2,.raw,.vmdk,.xz,.gz" style="display:none" @change="onFileSelect" />
          <div v-if="uploadFile" style="display:flex;align-items:center;gap:8px">
            <span style="font-weight:500">{{ uploadFile.name }}</span>
            <span class="mono" style="color:var(--text-dim)">{{ formatBytes(uploadFile.size) }}</span>
          </div>
          <div v-else style="color:var(--text-dim);font-size:13px">
            Click or drag a file here (.iso, .img, .qcow2, .raw)
          </div>
        </div>
      </div>
      <div class="form-group">
        <label>Name</label>
        <input v-model="uploadName" placeholder="My Image" :disabled="uploading" />
      </div>
      <div class="form-group">
        <label>Type</label>
        <AppSelect v-model="uploadType" :disabled="uploading">
          <option value="iso">ISO</option>
          <option value="cloud-image">Cloud Image / Disk</option>
        </AppSelect>
      </div>

      <div v-if="uploading" style="margin-bottom:12px">
        <ProgressBar :percent="uploadProgress">Uploading... {{ uploadProgress }}%</ProgressBar>
      </div>

      <FormError v-if="uploadError" :message="uploadError" />
      <div class="modal-actions">
        <AppButton @click="uploading ? cancelUpload() : (showUpload = false)">
          {{ uploading ? 'Cancel Upload' : 'Cancel' }}
        </AppButton>
        <AppButton v-if="!uploading" variant="primary" @click="startUpload">Upload</AppButton>
      </div>
    </div>
  </div>

  <!-- Download Modal -->
  <div v-if="showDownload" class="modal-overlay" @click.self="showDownload = false">
    <div class="modal">
      <h2>Download Image</h2>
      <div class="form-group">
        <label>Name</label>
        <input v-model="dlName" placeholder="Alpine Virt 3.21 ARM64" />
      </div>
      <div class="form-group">
        <label>Download URL</label>
        <input v-model="dlUrl" placeholder="https://..." />
      </div>
      <div class="form-group">
        <label>Type</label>
        <AppSelect v-model="dlType">
          <option value="iso">ISO</option>
          <option value="cloud-image">Cloud Image</option>
        </AppSelect>
      </div>
      <FormError v-if="dlError" :message="dlError" />
      <div class="modal-actions">
        <AppButton @click="showDownload = false">Cancel</AppButton>
        <AppButton variant="primary" :disabled="dlLoading" :loading="dlLoading" loading-text="Starting..." @click="startDownload">Download</AppButton>
      </div>
    </div>
  </div>

  <ConfirmDialog
    v-if="confirmTarget"
    title="Delete Image"
    :message="`Delete image &quot;${confirmTarget.name}&quot;? The file will be permanently removed.`"
    confirm-label="Delete"
    :danger="true"
    :loading="deleting"
    @confirm="doDeleteImage"
    @cancel="confirmTarget = null"
  />
</template>

<style scoped>
.file-drop {
  border: 2px dashed var(--border);
  border-radius: var(--radius);
  padding: 24px;
  text-align: center;
  cursor: pointer;
  transition: border-color 0.15s;
}
.file-drop:hover {
  border-color: var(--accent);
}
</style>
