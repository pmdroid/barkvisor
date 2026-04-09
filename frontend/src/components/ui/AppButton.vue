<script setup lang="ts">
import AppIcon from './AppIcon.vue'

defineProps<{
  variant?: 'primary' | 'ghost' | 'danger' | 'warning'
  size?: 'sm' | 'md'
  icon?: string
  loading?: boolean
  loadingText?: string
  disabled?: boolean
}>()

defineEmits<{ click: [e: MouseEvent] }>()
</script>

<template>
  <button
    :class="[
      'app-btn',
      'btn-' + (variant ?? 'ghost'),
      size === 'sm' && 'btn-sm',
    ]"
    :disabled="disabled || loading"
    @click="$emit('click', $event)"
  >
    <span class="app-btn-inner">
      <AppIcon v-if="icon" :name="icon" :size="size === 'sm' ? 12 : 14" />
      <slot>{{ loading ? (loadingText ?? 'Loading...') : '' }}</slot>
    </span>
  </button>
</template>

<style scoped>
.app-btn-inner {
  display: flex;
  align-items: center;
  gap: 6px;
}
</style>
