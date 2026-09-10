<script setup lang="ts">
import type { ComposeMount } from '../utils/composeMounts'

defineProps<{
  mounts: ComposeMount[]
  roots: string[]
}>()
</script>

<template>
  <div v-if="mounts.length === 0 && roots.length === 0" class="dim">No mounts recorded.</div>
  <div v-else class="mount-list">
    <div v-for="(m, i) in mounts" :key="i" class="mount">
      <span class="kind" :class="m.kind">{{ m.kind }}</span>
      <span class="paths">{{ m.source }}<span class="arrow">→</span>{{ m.target }}</span>
    </div>
  </div>
  <div v-if="roots.length" class="volume-root">
    Volume roots: <span class="mono">{{ roots.join(' · ') }}</span>
  </div>
</template>

<style scoped>
.mount-list {
  display: flex;
  flex-direction: column;
  gap: 7px;
  margin-bottom: 12px;
}
.mount {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 12.5px;
  min-width: 0;
}
.mount .kind {
  flex-shrink: 0;
  min-width: 58px;
  text-align: center;
  padding: 2px 6px;
  border-radius: var(--radius);
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}
.mount .kind.bind { background: rgba(0, 144, 248, 0.12); color: var(--accent); }
.mount .kind.volume { background: rgba(52, 211, 153, 0.12); color: var(--green); }
.mount .paths {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 12px;
  color: var(--text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  min-width: 0;
}
.mount .paths .arrow { color: var(--text-dim); margin: 0 5px; }
.volume-root {
  padding-top: 10px;
  border-top: 1px solid rgba(184, 184, 180, 0.08);
  font-size: 12px;
  color: var(--text-dim);
}
.volume-root .mono {
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  color: var(--text-secondary);
}
.dim { color: var(--text-dim); font-size: 13px; }
</style>
