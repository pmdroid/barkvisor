<script setup lang="ts">
import type { ComposeMount } from '../utils/composeMounts'

defineProps<{
  mounts: ComposeMount[]
  roots?: string[]
}>()
</script>

<template>
  <div v-if="mounts.length === 0 && !(roots && roots.length)" class="dim">No mounts recorded.</div>
  <div v-else class="vol-list">
    <div v-for="(m, i) in mounts" :key="i" class="vol-row">
      <span class="mount">{{ m.target }}</span>
      <span class="host-path">
        {{ m.source }}<span v-if="m.readOnly" class="ro"> (ro)</span>
      </span>
    </div>
  </div>
  <div v-if="roots && roots.length" class="volume-root">
    Volume roots: <span class="mono">{{ roots.join(' · ') }}</span>
  </div>
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
}
.ro { color: var(--text-dim); }
.volume-root {
  padding-top: 10px;
  border-top: 1px solid var(--border);
  font-size: 12px;
  color: var(--text-dim);
}
.volume-root .mono {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  color: var(--text-secondary);
}
.dim { color: var(--text-dim); font-size: 13px; }
</style>
