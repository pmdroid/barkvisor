<script setup lang="ts">
defineProps<{
  label: string
  self?: boolean
  reachable?: boolean
}>()
</script>

<template>
  <span class="device-chip" :class="{ self, down: reachable === false }">
    {{ label }}
    <span v-if="reachable === false" class="device-chip-down">unreachable</span>
  </span>
</template>

<style scoped>
.device-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  font-size: 9.5px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  padding: 2px 6px;
  border-radius: 2px;
  border: 0;
  background: rgba(0,144,248,0.14);
  color: var(--accent);
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
