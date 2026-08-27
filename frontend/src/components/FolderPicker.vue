<script setup lang="ts">
import { ref, onMounted, watch } from 'vue'
import api from '../api/client'
import { setupApi } from '../api/setup'
import { apiErrorMessage } from '../api/errors'
import type { DeviceApiTarget } from '../utils/homeDeviceApi'
import {
  asFolderEntries,
  folderBrowseParams,
  folderBrowseRequestPath,
  type FolderEntry,
} from '../utils/folderBrowse'
import FormError from './ui/FormError.vue'

const props = defineProps<{
  modelValue: string
  device?: DeviceApiTarget | null
  source?: 'system' | 'setup'
}>()
const emit = defineEmits(['update:modelValue', 'close'])

const currentPath = ref('')
const pendingSelect = ref('')
const entries = ref<FolderEntry[]>([])
const loading = ref(false)
const error = ref('')

function browseClient() {
  return props.source === 'setup' ? setupApi : api
}

onMounted(() => {
  browse('')
})

watch(
  () => props.device?.hostId,
  () => {
    browse('')
  },
)

async function browse(path: string) {
  loading.value = true
  error.value = ''
  try {
    const { data } = await browseClient().get(folderBrowseRequestPath(props.device, props.source), {
      params: folderBrowseParams(path),
    })
    entries.value = asFolderEntries(data)
    currentPath.value = path
    if (path) pendingSelect.value = path
  } catch (err) {
    error.value = apiErrorMessage(err, 'Unable to list folders')
    if (path) {
      try {
        const { data } = await browseClient().get(folderBrowseRequestPath(props.device, props.source), {
          params: folderBrowseParams(''),
        })
        entries.value = asFolderEntries(data)
        currentPath.value = ''
      } catch {
        entries.value = []
      }
    } else {
      entries.value = []
    }
  } finally {
    loading.value = false
  }
}

function chosenPath() {
  return currentPath.value || pendingSelect.value
}

function onEntryClick(entry: FolderEntry) {
  if (entry.name !== '..' && entry.path) pendingSelect.value = entry.path
  browse(entry.path)
}

function select() {
  const path = chosenPath()
  if (!path) return
  emit('update:modelValue', path)
  emit('close')
}
</script>

<template>
  <Teleport to="body">
    <div class="modal-overlay stack" @click.self="emit('close')">
      <div class="split-frame split-narrow">
        <section class="split-stage">
          <div class="split-head">
            <h2>Select Folder</h2>
            <p class="folder-current">{{ currentPath || 'Places' }}</p>
          </div>
          <div class="split-body">
            <FormError v-if="error" :message="error" />
            <div v-if="loading" class="folder-empty">Loading...</div>
            <div v-else class="folder-list">
              <button
                v-for="entry in entries"
                :key="`${entry.name}:${entry.path}`"
                type="button"
                class="folder-item"
                @click="onEntryClick(entry)"
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
                  <template v-if="entry.name === '..'">
                    <polyline points="15 18 9 12 15 6"/>
                  </template>
                  <template v-else>
                    <path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z"/>
                  </template>
                </svg>
                <span>{{ entry.name }}</span>
              </button>
              <div v-if="!entries.length" class="folder-empty">No folders</div>
            </div>
          </div>
          <div class="split-foot">
            <button class="btn-ghost" @click="emit('close')">Cancel</button>
            <button class="btn-primary" :disabled="!chosenPath()" @click="select">Select This Folder</button>
          </div>
        </section>
      </div>
    </div>
  </Teleport>
</template>

<style scoped>
.folder-current {
  font-family: var(--font-mono, ui-monospace, SFMono-Regular, Menlo, monospace);
  font-size: 12px;
  color: var(--text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.folder-list {
  border: 1px solid var(--line);
  border-radius: var(--radius);
  min-height: 160px;
  max-height: 280px;
  overflow-y: auto;
}
.folder-item {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  text-align: left;
  font: inherit;
  font-size: 13px;
  color: var(--text);
  background: none;
  padding: 8px 12px;
  cursor: pointer;
  border: 0;
  border-bottom: 1px solid var(--line);
}
.folder-item:last-child { border-bottom: none; }
.folder-item:hover { background: var(--bg-hover); }
.folder-empty {
  padding: 16px;
  text-align: center;
  color: var(--text-dim);
  font-size: 13px;
}
</style>
