<script setup lang="ts">
import { ref, onMounted } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import FormError from './ui/FormError.vue'

type FolderEntry = { name: string; path: string; isDirectory: boolean }

const props = defineProps<{ modelValue: string }>()
const emit = defineEmits(['update:modelValue', 'close'])

const currentPath = ref(props.modelValue || '')
const entries = ref<FolderEntry[]>([])
const loading = ref(false)
const error = ref('')

onMounted(() => {
  browse(props.modelValue || '')
})

function asEntries(data: unknown): FolderEntry[] {
  if (!Array.isArray(data)) return []
  return data.filter((row): row is FolderEntry => {
    if (!row || typeof row !== 'object') return false
    const item = row as FolderEntry
    return typeof item.name === 'string' && typeof item.path === 'string'
  })
}

function pathFromChild(child: FolderEntry): string {
  const cut = child.path.lastIndexOf('/')
  if (cut <= 0) return '/'
  return child.path.slice(0, cut)
}

async function browse(path: string) {
  loading.value = true
  error.value = ''
  try {
    const { data } = await api.get('/system/browse', { params: { path: path || undefined } })
    entries.value = asEntries(data)
    if (path) {
      currentPath.value = path
      return
    }
    const child = entries.value.find((row) => row.name !== '..')
    currentPath.value = child ? pathFromChild(child) : '/'
  } catch (err) {
    error.value = apiErrorMessage(err, 'Unable to list folders')
  } finally {
    loading.value = false
  }
}

function select() {
  if (!currentPath.value) return
  emit('update:modelValue', currentPath.value)
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
            <p class="folder-current">{{ currentPath || '/' }}</p>
          </div>
          <div class="split-body">
            <FormError v-if="error" :message="error" />
            <div v-if="loading" class="folder-empty">Loading...</div>
            <div v-else class="folder-list">
              <button
                v-for="entry in entries"
                :key="entry.path"
                type="button"
                class="folder-item"
                @click="browse(entry.path)"
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
              <div v-if="!entries.length" class="folder-empty">No subfolders</div>
            </div>
          </div>
          <div class="split-foot">
            <button class="btn-ghost" @click="emit('close')">Cancel</button>
            <button class="btn-primary" :disabled="!currentPath" @click="select">Select This Folder</button>
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
