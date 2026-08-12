<script setup lang="ts">
defineProps<{
  text?: string | null
}>()
</script>

<template>
  <p v-if="text" class="unsupported-hint">{{ text }}</p>
</template>

<style scoped>
.unsupported-hint {
  color: var(--text-dim);
  font-size: 12px;
  margin: 6px 0 0;
  line-height: 1.45;
}
</style>
