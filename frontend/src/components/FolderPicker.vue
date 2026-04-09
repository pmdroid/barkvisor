<script setup lang="ts">
import { ref, onMounted } from 'vue'
import api from '../api/client'

const props = defineProps<{ modelValue: string }>()
const emit = defineEmits(['update:modelValue', 'close'])

const currentPath = ref('')
const entries = ref<{ name: string; path: string; isDirectory: boolean }[]>([])
const loading = ref(false)

onMounted(() => {
  browse(props.modelValue || '')
})

async function browse(path: string) {
  loading.value = true
  try {
    const { data } = await api.get('/system/browse', { params: { path: path || undefined } })
    entries.value = data
    // Derive current path from first real entry or parent
    if (data.length > 0 && data[0].name === '..') {
      // Current = parent of the parent entry's path... easier to get from a real child
      const child = data.find((e: any) => e.name !== '..')
      if (child) {
        currentPath.value = child.path.substring(0, child.path.lastIndexOf('/')) || '/'
      } else {
        currentPath.value = path
      }
    } else {
      currentPath.value = path || '/'
    }
  } catch {
    // If browse fails, stay where we are
  } finally {
    loading.value = false
  }
}

function select() {
  emit('update:modelValue', currentPath.value)
  emit('close')
}
</script>

<template>
  <div class="modal-overlay" @click.self="emit('close')">
    <div class="modal" style="max-width:480px">
      <h2>Select Folder</h2>
      <div class="folder-path">{{ currentPath || '/' }}</div>

      <div class="folder-list">
        <div v-if="loading" style="padding:16px;text-align:center;color:var(--text-dim)">Loading...</div>
        <div v-else>
          <div
            v-for="entry in entries" :key="entry.path"
            class="folder-item"
            @click="browse(entry.path)"
            @dblclick="browse(entry.path)"
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
          </div>
          <div v-if="entries.length === 0" style="padding:16px;text-align:center;color:var(--text-dim);font-size:13px">
            No subfolders
          </div>
        </div>
      </div>

      <div class="modal-actions">
        <button class="btn-ghost" @click="emit('close')">Cancel</button>
        <button class="btn-primary" @click="select">Select This Folder</button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.folder-path {
  font-family: var(--font-mono);
  font-size: 12px;
  color: var(--text-secondary);
  padding: 8px 12px;
  background: var(--bg);
  border-radius: var(--radius-sm);
  margin-bottom: 12px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.folder-list {
  border: 1px solid var(--border);
  border-radius: var(--radius-sm);
  max-height: 280px;
  overflow-y: auto;
  margin-bottom: 16px;
}
.folder-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 12px;
  font-size: 13px;
  cursor: pointer;
  border-bottom: 1px solid var(--border-subtle);
  transition: background 0.1s;
}
.folder-item:last-child { border-bottom: none; }
.folder-item:hover { background: var(--bg-hover); }
</style>
