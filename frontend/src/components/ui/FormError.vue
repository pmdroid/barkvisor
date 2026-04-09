<script setup lang="ts">
defineProps<{ message: string }>()
</script>

<template>
  <p class="form-error">{{ message }}</p>
</template>

<style scoped>
.form-error {
  color: var(--red);
  font-size: 13px;
  margin-bottom: 12px;
  background: var(--red-muted);
  padding: 8px 12px;
  border-radius: var(--radius-xs);
}
</style>
