<script setup lang="ts">
defineProps<{
  title: string
  maxWidth?: string
}>()

defineEmits<{ close: [] }>()
</script>

<template>
  <div class="modal-overlay" @click.self="$emit('close')">
    <div class="modal" :style="maxWidth ? { width: maxWidth } : undefined">
      <h2>{{ title }}</h2>
      <slot />
      <div v-if="$slots.actions" class="modal-actions">
        <slot name="actions" />
      </div>
    </div>
  </div>
</template>
