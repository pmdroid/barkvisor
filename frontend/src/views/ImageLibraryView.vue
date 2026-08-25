<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { onMounted, onUnmounted, ref, reactive, computed, watch } from 'vue'
import { useImageStore } from '../stores/images'
import { useCapabilitiesStore } from '../stores/capabilities'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useImageProgress } from '../composables/useTicketedEventSource'
import * as tus from 'tus-js-client'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import DataTable from '../components/ui/DataTable.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import FormError from '../components/ui/FormError.vue'
import ProgressBar from '../components/ui/ProgressBar.vue'
import { formatBytes } from '../utils/format'
import { scopeRows } from '../utils/deviceScope'
import {
  detectImageArch,
  hostArchToImageArch,
  resolveImageArch,
  type ImageArch,
} from '../utils/imageArch'

const store = useImageStore()
const caps = useCapabilitiesStore()
const devicesStore = useDevicesStore()
const deviceScope = useDeviceScopeStore()

const visibleImages = computed(() =>
  scopeRows(
    store.images.map((image) => ({
      image,
      hostId: devicesStore.selfDevice?.hostId || '',
    })),
    deviceScope.selectedHostId,
  ).map((row) => row.image),
)

const defaultArch = computed<ImageArch>(() => hostArchToImageArch(caps.hostArch))

const showDownload = ref(false)
const dlName = ref('')
const dlUrl = ref('')
const dlType = ref<'iso' | 'cloud-image'>('iso')
const dlArch = ref<ImageArch>('arm64')
const dlArchHint = ref('')
const dlArchManual = ref(false)
const dlLoading = ref(false)
const dlError = ref('')

// Upload state
const showUpload = ref(false)
const uploadName = ref('')
const uploadType = ref<'iso' | 'cloud-image'>('iso')
const uploadArch = ref<ImageArch>('arm64')
const uploadArchHint = ref('')
const uploadArchManual = ref(false)
const uploadFile = ref<File | null>(null)
const uploadError = ref('')
const uploadProgress = ref(0)
const uploading = ref(false)
const fileInputRef = ref<HTMLInputElement>()
let currentUpload: tus.Upload | null = null

// Download progress tracking via ticketed SSE
const downloadProgress = reactive<Record<string, { percent: number; bytesReceived: number; totalBytes: number | null; status: string }>>({})
const progressStreams: Record<string, ReturnType<typeof useImageProgress>> = {}

function subscribeDownloading() {
  for (const img of store.images) {
    if ((img.status === 'downloading' || img.status === 'decompressing') && !progressStreams[img.id]) {
      const stream = useImageProgress()
      progressStreams[img.id] = stream
      stream.start(img.id, {
        onProgress: (data) => {
          downloadProgress[img.id] = {
            percent: data.percent ?? 0,
            bytesReceived: data.bytesReceived ?? 0,
            totalBytes: data.totalBytes ?? null,
            status: data.status ?? 'downloading',
          }
        },
        onReady: () => {
          stream.stop()
          delete progressStreams[img.id]
          delete downloadProgress[img.id]
          store.fetchAll()
        },
        onError: () => {
          stream.stop()
          delete progressStreams[img.id]
          delete downloadProgress[img.id]
          store.fetchAll()
        },
      })
    }
  }
}

let pollTimer: number

function resetDownloadForm() {
  dlName.value = ''
  dlUrl.value = ''
  dlType.value = 'iso'
  dlArch.value = defaultArch.value
  dlArchHint.value = ''
  dlArchManual.value = false
  dlError.value = ''
}

function resetUploadForm() {
  uploadName.value = ''
  uploadType.value = 'iso'
  uploadArch.value = defaultArch.value
  uploadArchHint.value = ''
  uploadArchManual.value = false
  uploadFile.value = null
  uploadError.value = ''
  uploadProgress.value = 0
  if (fileInputRef.value) fileInputRef.value.value = ''
}

function openDownload() {
  resetDownloadForm()
  showDownload.value = true
}

function openUpload() {
  resetUploadForm()
  showUpload.value = true
}

function applyDetectedArch(
  source: string,
  target: 'download' | 'upload',
) {
  const detected = detectImageArch(source)
  if (target === 'download') {
    if (dlArchManual.value) return
    if (detected.arch) {
      dlArch.value = detected.arch
      dlArchHint.value = `Detected ${detected.arch} from “${detected.matched}” in the URL/filename`
    } else {
      dlArch.value = defaultArch.value
      dlArchHint.value = source.trim()
        ? `Could not detect arch from URL — using device default (${defaultArch.value})`
        : ''
    }
  } else {
    if (uploadArchManual.value) return
    if (detected.arch) {
      uploadArch.value = detected.arch
      uploadArchHint.value = `Detected ${detected.arch} from “${detected.matched}” in the filename`
    } else {
      uploadArch.value = defaultArch.value
      uploadArchHint.value = source.trim()
        ? `Could not detect arch from filename — using device default (${defaultArch.value})`
        : ''
    }
  }
}

function setDlArchManual(value: string) {
  dlArch.value = value as ImageArch
  dlArchManual.value = true
  dlArchHint.value = 'Architecture set manually'
}

function setUploadArchManual(value: string) {
  uploadArch.value = value as ImageArch
  uploadArchManual.value = true
  uploadArchHint.value = 'Architecture set manually'
}

watch(dlUrl, (url) => {
  if (!showDownload.value) return
  applyDetectedArch(url, 'download')
  // Soft-fill name from last path segment if empty
  if (!dlName.value.trim() && url.trim()) {
    try {
      const path = new URL(url).pathname
      const base = path.split('/').pop() || ''
      if (base) dlName.value = base.replace(/\.(iso|img|qcow2|raw|vmdk)(\.(xz|gz|bz2|zst))?$/i, '')
    } catch { /* ignore */ }
  }
  // Soft-fill type from extension
  const lower = url.toLowerCase()
  if (lower.includes('.iso')) dlType.value = 'iso'
  else if (/\.(img|qcow2|raw|vmdk)(\.|$)/i.test(lower)) dlType.value = 'cloud-image'
})

onMounted(async () => {
  await caps.fetchCapabilities().catch(() => {})
  dlArch.value = defaultArch.value
  uploadArch.value = defaultArch.value
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
  Object.values(progressStreams).forEach(s => s.stop())
})

async function startDownload() {
  dlError.value = ''
  if (!dlName.value.trim() || !dlUrl.value.trim()) { dlError.value = 'Name and URL required'; return }
  dlLoading.value = true
  try {
    const arch = dlArchManual.value
      ? dlArch.value
      : resolveImageArch(dlUrl.value, caps.hostArch)
    await store.startDownload({
      name: dlName.value.trim(),
      url: dlUrl.value.trim(),
      imageType: dlType.value,
      arch,
    })
    showDownload.value = false
    resetDownloadForm()
    await store.fetchAll()
    setTimeout(subscribeDownloading, 500)
  } catch (e: any) {
    dlError.value = apiErrorMessage(e)
  } finally {
    dlLoading.value = false
  }
}

function applyFileMeta(file: File) {
  uploadFile.value = file
  if (!uploadName.value) {
    uploadName.value = file.name.replace(/\.\w+$/, '')
  }
  const name = file.name.toLowerCase()
  if (name.endsWith('.iso')) {
    uploadType.value = 'iso'
  } else {
    uploadType.value = 'cloud-image'
  }
  // Reset manual flag only when picking a new file so detection runs
  uploadArchManual.value = false
  applyDetectedArch(file.name, 'upload')
}

function onFileSelect(e: Event) {
  const input = e.target as HTMLInputElement
  if (input.files?.length) {
    applyFileMeta(input.files[0])
  }
}

function onFileDrop(e: DragEvent) {
  if (e.dataTransfer?.files.length) {
    applyFileMeta(e.dataTransfer.files[0])
  }
}

function startUpload() {
  uploadError.value = ''
  if (!uploadFile.value) { uploadError.value = 'Select a file'; return }
  if (!uploadName.value.trim()) { uploadError.value = 'Name required'; return }

  const token = localStorage.getItem('token')
  uploading.value = true
  uploadProgress.value = 0

  const arch = uploadArchManual.value
    ? uploadArch.value
    : resolveImageArch(uploadFile.value.name, caps.hostArch)

  const upload = new tus.Upload(uploadFile.value, {
    endpoint: '/api/images/tus',
    retryDelays: [0, 1000, 3000, 5000],
    chunkSize: 5 * 1024 * 1024, // 5 MB chunks
    metadata: {
      name: uploadName.value.trim(),
      imageType: uploadType.value,
      arch,
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
      resetUploadForm()
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
    await store.remove(id)
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
      <AppButton icon="upload" @click="openUpload">Upload Image</AppButton>
      <AppButton variant="primary" icon="download" @click="openDownload">Download Image</AppButton>
    </div>
  </div>

  <EmptyState v-if="visibleImages.length === 0 && !store.loading" icon="image" title="No images yet" subtitle="Upload an ISO/disk image or download one from a URL" />

  <DataTable v-else :columns="[{ key: 'name', label: 'Name' }, { key: 'type', label: 'Type' }, { key: 'arch', label: 'Arch' }, { key: 'size', label: 'Size' }, { key: 'status', label: 'Status' }, { key: 'actions', label: '' }]">
        <tr v-for="img in visibleImages" :key="img.id">
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
        <div
          class="file-drop"
          @click="fileInputRef?.click()"
          @dragover.prevent
          @drop.prevent="onFileDrop"
        >
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
      <div class="form-row">
        <div class="form-group" style="flex:1">
          <label>Type</label>
          <AppSelect v-model="uploadType" :disabled="uploading">
            <option value="iso">ISO</option>
            <option value="cloud-image">Cloud Image / Disk</option>
          </AppSelect>
        </div>
        <div class="form-group" style="flex:1">
          <label>Architecture</label>
          <AppSelect
            :model-value="uploadArch"
            :disabled="uploading"
            @update:model-value="setUploadArchManual"
          >
            <option value="arm64">arm64 (AArch64)</option>
            <option value="x86_64">x86_64 (amd64)</option>
          </AppSelect>
          <p v-if="uploadArchHint" class="arch-hint">{{ uploadArchHint }}</p>
        </div>
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
        <input v-model="dlName" placeholder="Ubuntu 24.04 Server" />
      </div>
      <div class="form-group">
        <label>Download URL</label>
        <input v-model="dlUrl" placeholder="https://…/Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso" />
      </div>
      <div class="form-row">
        <div class="form-group" style="flex:1">
          <label>Type</label>
          <AppSelect v-model="dlType">
            <option value="iso">ISO</option>
            <option value="cloud-image">Cloud Image</option>
          </AppSelect>
        </div>
        <div class="form-group" style="flex:1">
          <label>Architecture</label>
          <AppSelect :model-value="dlArch" @update:model-value="setDlArchManual">
            <option value="arm64">arm64 (AArch64)</option>
            <option value="x86_64">x86_64 (amd64)</option>
          </AppSelect>
          <p v-if="dlArchHint" class="arch-hint">{{ dlArchHint }}</p>
        </div>
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
.form-row {
  display: flex;
  gap: 12px;
}
.arch-hint {
  margin: 6px 0 0;
  font-size: 12px;
  color: var(--text-dim);
  line-height: 1.35;
}
</style>
