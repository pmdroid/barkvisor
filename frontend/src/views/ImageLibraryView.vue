<script setup lang="ts">
import { apiErrorMessage } from '../api/errors'
import { onActivated, onMounted, onUnmounted, ref, reactive, computed, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useImageStore } from '../stores/images'
import { useCapabilitiesStore } from '../stores/capabilities'
import { useDevicesStore } from '../stores/devices'
import { useDeviceScopeStore } from '../stores/deviceScope'
import { useHomeLibraryStore, type HomeImage } from '../stores/homeLibrary'
import { useDeviceWorkloadsStore } from '../stores/deviceWorkloads'
import { useVMStore } from '../stores/vms'
import { useImageProgress } from '../composables/useTicketedEventSource'
import * as tus from 'tus-js-client'
import ConfirmDialog from '../components/ConfirmDialog.vue'
import AppButton from '../components/ui/AppButton.vue'
import AppSelect from '../components/ui/AppSelect.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import FormError from '../components/ui/FormError.vue'
import ProgressBar from '../components/ui/ProgressBar.vue'
import api from '../api/client'
import type { LibrarySettings } from '../api/types'
import { formatBytes } from '../utils/format'
import { isDeviceScopeAll, scopeRows } from '../utils/deviceScope'
import { imageProgressPercent } from '../utils/imageProgress'
import { librarySpaceCopy, onLibrarySettingsChanged } from '../utils/librarySpace'
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
const homeLibrary = useHomeLibraryStore()
const homeWorkloads = useDeviceWorkloadsStore()
const vmStore = useVMStore()
const route = useRoute()
const librarySettings = ref<LibrarySettings | null>(null)
const librarySpaceLoaded = ref(false)
const librarySpaceLine = computed(() => {
  const total = librarySettings.value?.totalBytes
  const used = librarySettings.value?.usedBytes
  if (total != null && used != null && total > 0) {
    return `${formatBytes(used)} of ${formatBytes(total)} used`
  }
  return librarySpaceCopy(librarySettings.value?.totalBytes, librarySettings.value?.freeBytes)
})
const libraryCapPercent = computed(() => {
  const total = librarySettings.value?.totalBytes
  const used = librarySettings.value?.usedBytes
  if (total == null || total <= 0 || used == null) return null
  return Math.min(100, Math.round((used / total) * 100))
})

function imageRowsFromLibrary(images: HomeImage[]) {
  return images.flatMap((img) =>
    img.copies.map((copy) => ({
      ...img,
      id: copy.imageId,
      status: copy.status,
      hostId: copy.hostId,
    })),
  )
}

const visibleImages = computed(() => {
  if (homeLibrary.images.length > 0) {
    return scopeRows(imageRowsFromLibrary(homeLibrary.images), deviceScope.selectedHostId)
  }
  if (
    !isDeviceScopeAll(deviceScope.selectedHostId)
    && devicesStore.selfDevice
    && deviceScope.selectedHostId !== devicesStore.selfDevice.hostId
  ) {
    return []
  }
  return store.images
})

async function fetchLibrarySpace() {
  try {
    const { data } = await api.get<LibrarySettings>('/system/library/settings')
    librarySettings.value = data
  } catch {
    librarySettings.value = null
  } finally {
    librarySpaceLoaded.value = true
  }
}
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
const downloadProgress = reactive<Record<string, { percent: number | null; bytesReceived: number; totalBytes: number | null; status: string }>>({})
const progressStreams: Record<string, ReturnType<typeof useImageProgress>> = {}

function isTransferringStatus(status: string | undefined) {
  return status === 'downloading' || status === 'decompressing'
}

function imageTypeLabel(type: string): string {
  return type === 'iso' ? 'Installer ISO' : 'Disk image'
}

function imageFileName(img: { name: string; sourceUrl: string | null; imageType: string; arch: string }): string {
  const src = img.sourceUrl?.trim()
  if (src) {
    try {
      const path = new URL(src).pathname
      const base = path.split('/').pop()
      if (base) return decodeURIComponent(base)
    } catch {
      const base = src.split('/').pop()
      if (base) return base
    }
  }
  const ext = img.imageType === 'iso' ? 'iso' : 'qcow2'
  return `${img.name.toLowerCase().replace(/\s+/g, '-')}-${img.arch}.${ext}`
}

function usedByNames(img: { id: string }): string {
  const vms = devicesStore.devices.length
    ? homeWorkloads.homeRows(devicesStore.devices).map((row) => row.vm)
    : vmStore.vms
  const names = vms
    .filter((vm) => vm.isoId === img.id || (vm.isoIds ?? []).includes(img.id))
    .map((vm) => vm.name)
  return names.length ? `used by ${names.join(', ')}` : ''
}

function subscribeDownloading() {
  for (const id of Object.keys(progressStreams)) {
    const img = store.images.find(i => i.id === id)
    if (!img || !isTransferringStatus(img.status)) {
      progressStreams[id]?.stop()
      delete progressStreams[id]
      delete downloadProgress[id]
    }
  }
  for (const img of store.images) {
    if (isTransferringStatus(img.status) && !progressStreams[img.id]) {
      const stream = useImageProgress()
      progressStreams[img.id] = stream
      stream.start(img.id, {
        onOpen: () => {
          delete downloadProgress[img.id]
        },
        onProgress: (data) => {
          downloadProgress[img.id] = {
            percent: imageProgressPercent(data),
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
          void homeLibrary.fetchImages(devicesStore.devices)
        },
        onError: () => {
          stream.stop()
          delete progressStreams[img.id]
          delete downloadProgress[img.id]
          store.fetchAll().then(() => subscribeDownloading())
          void homeLibrary.fetchImages(devicesStore.devices)
        },
      })
    }
  }
}

let pollTimer: number
let stopLibrarySettingsWatch: (() => void) | null = null

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
  void fetchLibrarySpace()
  stopLibrarySettingsWatch?.()
  stopLibrarySettingsWatch = onLibrarySettingsChanged(() => {
    void fetchLibrarySpace()
  })
  await devicesStore.fetchHealth().catch(() => {})
  await Promise.all([
    store.fetchAll(),
    homeLibrary.fetchImages(devicesStore.devices),
    devicesStore.devices.length
      ? homeWorkloads.fetchHomeAll(devicesStore.devices)
      : vmStore.fetchAll(),
  ])
  subscribeDownloading()
  pollTimer = window.setInterval(() => {
    if (store.images.some(i => i.status === 'downloading' || i.status === 'uploading' || i.status === 'decompressing')) {
      store.fetchAll().then(() => {
        subscribeDownloading()
        void homeLibrary.fetchImages(devicesStore.devices)
      })
    }
  }, 5000)
})

onActivated(() => {
  void fetchLibrarySpace()
})

watch(
  () => route.name,
  (name) => {
    if (name === 'images') void fetchLibrarySpace()
  },
)

onUnmounted(() => {
  stopLibrarySettingsWatch?.()
  stopLibrarySettingsWatch = null
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
    await homeLibrary.fetchImages(devicesStore.devices)
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
      void homeLibrary.fetchImages(devicesStore.devices)
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
    await homeLibrary.fetchImages(devicesStore.devices)
  } finally {
    deleting.value = false
    confirmTarget.value = null
  }
}

</script>

<template>
  <div class="ops-page">
  <div class="ops-toolbar">
    <h1>Images</h1>
    <div v-if="librarySpaceLine" class="cap">
      <span class="track"><span class="cf" :style="{ width: (libraryCapPercent ?? 0) + '%' }"></span></span>
      {{ librarySpaceLine }}
    </div>
    <span v-else-if="librarySpaceLoaded" class="ops-sub">Capacity unavailable</span>
    <div class="ops-actions">
      <AppButton icon="upload" @click="openUpload">Upload</AppButton>
      <AppButton variant="primary" icon="download" @click="openDownload">Download</AppButton>
    </div>
  </div>
  <div class="ops-body">

  <EmptyState v-if="visibleImages.length === 0 && !store.loading && !homeLibrary.imagesLoading" icon="image" title="No images yet" subtitle="Upload an ISO/disk image or download one from a URL" />

  <div v-else class="sheet">
  <table>
    <thead>
      <tr><th>Name</th><th>Type</th><th>Arch</th><th>Size</th><th>Status</th><th></th></tr>
    </thead>
    <tbody>
        <tr v-for="img in visibleImages" :key="'hostId' in img ? `${img.hostId}:${img.id}` : img.id" :class="{ pending: isTransferringStatus(img.status) || img.status === 'uploading' }">
          <td>
            <div class="img">{{ img.name }}</div>
            <div class="row-sub">{{ imageFileName(img) }}</div>
            <div v-if="downloadProgress[img.id]" class="prog">
              <span class="track"><span class="pf" :style="{ width: (downloadProgress[img.id].percent ?? 0) + '%' }"></span></span>
              <span class="pct">{{ downloadProgress[img.id].percent ?? 0 }}%</span>
            </div>
          </td>
          <td>{{ imageTypeLabel(img.imageType) }}</td>
          <td><span class="arch">{{ img.arch }}</span></td>
          <td class="num">{{ formatBytes(img.sizeBytes) }}</td>
          <td>
            <span class="state" :class="img.status === 'ready' ? 'ok' : img.status === 'error' ? 'bad' : 'warn'">
              <span class="ops-dot" :class="img.status === 'ready' ? 'ok' : img.status === 'error' ? 'bad' : 'warn pulse'"></span>
              {{ img.status === 'ready' ? 'Ready' : img.status === 'downloading' ? 'Downloading' : img.status }}
            </span>
            <div v-if="usedByNames(img)" class="row-sub">{{ usedByNames(img) }}</div>
          </td>
          <td class="del">
            <button type="button" class="icon-btn" aria-label="Delete" @click="deleteImage(img.id, img.name)">
              <svg width="12" height="12" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><path d="M2 3.5h10M5.5 3.5v-1h3v1M3.5 3.5l.5 8.5h6l.5-8.5M5.8 6v3.5M8.2 6v3.5"/></svg>
            </button>
          </td>
        </tr>
    </tbody>
  </table>
  </div>
  </div>

  <!-- Upload Modal -->
  <div v-if="showUpload" class="modal-overlay" @click.self="!uploading && (showUpload = false)">
    <div class="split-frame">
      <aside class="split-rail">
        <h3>Image</h3>
        <div class="split-s on">
          <span class="wizard-dot active">1</span>
          <div><div class="t">File</div><div class="d">Local upload</div></div>
        </div>
        <div class="split-s">
          <span class="wizard-dot">2</span>
          <div><div class="t">Identity</div><div class="d">Type · arch</div></div>
        </div>
      </aside>
      <section class="split-stage">
        <div class="split-head">
          <h2>Upload Image</h2>
          <p>The file lands in this Device’s Library.</p>
        </div>
        <div class="split-body">
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
        </div>
        <div class="split-foot">
        <AppButton @click="uploading ? cancelUpload() : (showUpload = false)">
          {{ uploading ? 'Cancel Upload' : 'Cancel' }}
        </AppButton>
        <AppButton v-if="!uploading" variant="primary" @click="startUpload">Upload</AppButton>
        </div>
      </section>
    </div>
  </div>

  <div v-if="showDownload" class="modal-overlay" @click.self="showDownload = false">
    <div class="split-frame">
      <aside class="split-rail">
        <h3>Image</h3>
        <div class="split-s on">
          <span class="wizard-dot active">1</span>
          <div><div class="t">Source</div><div class="d">URL</div></div>
        </div>
        <div class="split-s">
          <span class="wizard-dot">2</span>
          <div><div class="t">Identity</div><div class="d">Type · arch</div></div>
        </div>
      </aside>
      <section class="split-stage">
        <div class="split-head">
          <h2>Download Image</h2>
          <p>Lands in this Device’s Library.</p>
        </div>
        <div class="split-body">
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
        </div>
        <div class="split-foot">
        <AppButton @click="showDownload = false">Cancel</AppButton>
        <AppButton variant="primary" :disabled="dlLoading" :loading="dlLoading" loading-text="Starting..." @click="startDownload">Download</AppButton>
        </div>
      </section>
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
  </div>
</template>

<style scoped>
.sheet :deep(.data-table-wrap) {
  background: transparent;
  border: 0;
  border-radius: 0;
  box-shadow: none;
  backdrop-filter: none;
}
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
