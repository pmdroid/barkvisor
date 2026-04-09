<script setup lang="ts">
import { ref, watch, computed } from 'vue'
import { useRepositoryStore } from '../stores/repositories'
import { useToastStore } from '../stores/toast'
import type { RepositoryImage } from '../api/types'
import AppSelect from './ui/AppSelect.vue'

const props = defineProps<{ repoId: string }>()
const store = useRepositoryStore()
const images = ref<RepositoryImage[]>([])
const loading = ref(false)
const filterType = ref<string>('')
const downloading = ref<Set<string>>(new Set())

async function fetchImages() {
  loading.value = true
  try {
    images.value = await store.fetchImages(props.repoId)
  } finally {
    loading.value = false
  }
}

watch(() => props.repoId, fetchImages, { immediate: true })

const filteredImages = computed(() => {
  return images.value.filter(img => {
    if (img.arch !== 'arm64') return false
    if (filterType.value && img.imageType !== filterType.value) return false
    return true
  })
})

const types = computed(() => [...new Set(images.value.map(i => i.imageType))])

function formatSize(bytes: number | null): string {
  if (!bytes) return '-'
  if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + ' GB'
  return (bytes / 1048576).toFixed(0) + ' MB'
}

const toast = useToastStore()

async function download(img: RepositoryImage) {
  downloading.value.add(img.id)
  try {
    await store.downloadImage(img.id)
    toast.success(`Download started for "${img.name}"`, { label: 'View in Images', to: '/images' })
  } catch (e: any) {
    toast.error(e.response?.data?.reason || e.message)
  } finally {
    downloading.value.delete(img.id)
  }
}
</script>

<template>
  <div>
    <div style="display:flex;align-items:center;gap:12px;margin-bottom:16px">
      <h2 style="margin:0;font-size:16px;font-weight:700">Catalog</h2>
      <AppSelect v-model="filterType" size="sm">
        <option value="">All types</option>
        <option v-for="t in types" :key="t" :value="t">{{ t }}</option>
      </AppSelect>
    </div>

    <div v-if="loading" class="empty" style="padding:32px"><p>Loading catalog...</p></div>
    <div v-else-if="filteredImages.length === 0" class="empty" style="padding:32px"><p>No images match the current filters.</p></div>
    <div v-else style="background:var(--bg-card);backdrop-filter:var(--glass-blur);border:1px solid var(--border-glass);border-radius:var(--radius);overflow:hidden">
      <table>
        <thead><tr><th>Name</th><th>Type</th><th>Arch</th><th>Version</th><th>Size</th><th></th></tr></thead>
        <tbody>
          <tr v-for="img in filteredImages" :key="img.id">
            <td>
              <div style="font-weight:500">{{ img.name }}</div>
              <div v-if="img.description" style="font-size:12px;color:var(--text-dim);margin-top:2px">{{ img.description }}</div>
            </td>
            <td><span class="badge" :class="img.imageType === 'iso' ? 'badge-blue' : 'badge-purple'">{{ img.imageType }}</span></td>
            <td><span class="badge badge-gray">{{ img.arch }}</span></td>
            <td class="mono" style="color:var(--text-secondary)">{{ img.version || '-' }}</td>
            <td class="mono" style="color:var(--text-secondary)">{{ formatSize(img.sizeBytes) }}</td>
            <td style="text-align:right">
              <button class="btn-primary btn-sm" :disabled="downloading.has(img.id)" @click="download(img)">
                {{ downloading.has(img.id) ? 'Starting...' : 'Download' }}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
