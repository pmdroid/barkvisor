<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { isManagedAppMount, type ComposeMount } from '../utils/composeMounts'
import { composeBindFromDraft, type ComposeMountDraft } from '../utils/composeEdit'
import AppButton from './ui/AppButton.vue'

const props = defineProps<{
  mounts: ComposeMount[]
  roots?: string[]
  editable?: boolean
  busy?: boolean
  pickedHost?: string
}>()

const emit = defineEmits<{
  'add-mount': [ComposeMountDraft]
  'remove-mount': [ComposeMount]
  'pick-host': []
}>()

const hostPath = ref('')
const containerPath = ref('')
const readOnly = ref(false)

watch(
  () => props.pickedHost,
  (path) => {
    if (path) hostPath.value = path
  },
)

const canAdd = computed(() => Boolean(composeBindFromDraft({
  source: hostPath.value,
  target: containerPath.value,
  readOnly: readOnly.value,
})))

function isManaged(mount: ComposeMount): boolean {
  return isManagedAppMount(mount, props.roots)
}

function addMount() {
  const draft = composeBindFromDraft({
    source: hostPath.value,
    target: containerPath.value,
    readOnly: readOnly.value,
  })
  if (!draft) return
  emit('add-mount', draft)
  hostPath.value = ''
  containerPath.value = ''
  readOnly.value = false
}

function removeMount(mount: ComposeMount) {
  if (isManaged(mount)) return
  emit('remove-mount', mount)
}
</script>

<template>
  <div v-if="!editable && mounts.length === 0 && !(roots && roots.length)" class="dim">No mounts recorded.</div>
  <div v-else-if="mounts.length" class="vol-list">
    <div v-for="(m, i) in mounts" :key="i" class="vol-row">
      <span class="mount">{{ m.target }}</span>
      <span class="host-path">
        {{ m.source }}<span v-if="m.readOnly" class="ro"> (ro)</span>
      </span>
      <button
        v-if="editable && !isManaged(m)"
        class="row-remove"
        type="button"
        :disabled="busy"
        @click="removeMount(m)"
      >Remove</button>
      <span v-else-if="editable && isManaged(m)" class="managed-tag">managed</span>
    </div>
  </div>
  <div v-else-if="editable" class="dim">No mounts yet — add one below.</div>
  <template v-if="editable">
    <div class="draft-row">
      <input
        v-model="hostPath"
        class="mono"
        type="text"
        aria-label="Host folder"
        placeholder="/data/host-path"
        :disabled="busy"
      />
      <AppButton size="sm" :disabled="busy" @click="emit('pick-host')">Choose</AppButton>
      <input
        v-model="containerPath"
        class="mono"
        type="text"
        aria-label="Container path"
        placeholder="/container/path"
        :disabled="busy"
      />
      <label class="ro-toggle">
        <input v-model="readOnly" type="checkbox" :disabled="busy" aria-label="Read only" />
        <span>ro</span>
      </label>
      <AppButton size="sm" variant="primary" :disabled="busy || !canAdd" @click="addMount">Add</AppButton>
    </div>
  </template>
  <details v-if="roots && roots.length" class="volume-root">
    <summary>Allowed host folders ({{ roots.length }})</summary>
    <ul>
      <li v-for="root in roots" :key="root" class="mono" :title="root">{{ root }}</li>
    </ul>
  </details>
</template>

<style scoped>
.vol-list { display: flex; flex-direction: column; }
.vol-row {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 12px;
  padding: 9px 0;
  border-bottom: 1px solid var(--border);
  font-size: 12.5px;
}
.vol-row:last-child { border-bottom: none; }
.mount {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 12px;
  color: var(--text);
}
.host-path {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 11.5px;
  color: var(--text-dim);
  text-align: right;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  min-width: 0;
  margin-left: auto;
}
.ro { color: var(--text-dim); }
.managed-tag {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--text-dim);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 1px 6px;
  flex-shrink: 0;
}
.row-remove {
  background: none;
  border: none;
  color: var(--red);
  font-size: 11.5px;
  font-weight: 600;
  cursor: pointer;
  padding: 2px 4px;
  flex-shrink: 0;
  font-family: inherit;
}
.row-remove:disabled { opacity: 0.5; cursor: not-allowed; }
.draft-row {
  display: flex;
  gap: 8px;
  align-items: center;
  margin-top: 10px;
}
.draft-row input[type="text"] {
  background: var(--bg-input);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 7px 9px;
  flex: 1;
  min-width: 0;
}
.mono { font-family: ui-monospace, 'SF Mono', Menlo, monospace; font-size: 12px; }
.ro-toggle {
  display: flex;
  align-items: center;
  gap: 5px;
  font-size: 12px;
  color: var(--text-dim);
  flex-shrink: 0;
}
.volume-root {
  padding-top: 10px;
  border-top: 1px solid var(--border);
  font-size: 12px;
  color: var(--text-dim);
}
.volume-root summary {
  width: fit-content;
  cursor: pointer;
  color: var(--text-secondary);
}
.volume-root ul {
  display: grid;
  gap: 5px;
  margin: 9px 0 0;
  padding: 0;
  list-style: none;
}
.volume-root li {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  color: var(--text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.dim { color: var(--text-dim); font-size: 13px; }
@media (max-width: 600px) {
  .draft-row {
    display: grid;
    grid-template-columns: minmax(0, 1fr) auto;
  }
  .draft-row input[type="text"]:nth-of-type(2) {
    grid-column: 1;
  }
  .draft-row .ro-toggle {
    justify-self: start;
  }
  .draft-row :deep(.app-btn:last-child) {
    grid-column: 2;
    grid-row: 2;
  }
}
</style>
