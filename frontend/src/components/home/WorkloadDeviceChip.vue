<script setup lang="ts">
import { DEVICE_LABEL } from '../../utils/terminology'

defineProps<{
  label: string
  self?: boolean
  reachable?: boolean
}>()
</script>

<template>
  <span class="device-chip" :class="{ self, down: reachable === false }">
    {{ self ? `This ${DEVICE_LABEL}` : label }}
    <span v-if="reachable === false" class="device-chip-down">unreachable</span>
  </span>
</template>

<style scoped>
.device-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  padding: 2px 6px;
  border-radius: 999px;
  border: 1px solid var(--border);
  color: var(--text-dim);
  white-space: nowrap;
}
.device-chip.self {
  border-color: var(--accent);
  color: var(--accent);
}
.device-chip.down {
  border-color: var(--red, #ef4444);
  color: var(--red, #ef4444);
}
.device-chip-down {
  text-transform: none;
  letter-spacing: 0;
  font-size: 10px;
}
</style>
