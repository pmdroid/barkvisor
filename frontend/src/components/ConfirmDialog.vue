<script setup lang="ts">
defineProps<{
  title: string
  message: string
  confirmLabel?: string
  danger?: boolean
  loading?: boolean
}>()
const emit = defineEmits(['confirm', 'cancel'])
</script>

<template>
  <div class="modal-overlay" @click.self="!loading && emit('cancel')">
    <div class="modal" style="max-width:400px">
      <h2>{{ title }}</h2>
      <p style="color:var(--text-secondary);font-size:13px;margin-bottom:16px;line-height:1.5">{{ message }}</p>
      <div class="modal-actions">
        <button class="btn-ghost" :disabled="loading" @click="emit('cancel')">Cancel</button>
        <button
          class="btn-primary"
          :style="danger ? 'background:var(--red);border-color:var(--red)' : ''"
          :disabled="loading"
          @click="emit('confirm')"
        >{{ loading ? (confirmLabel || 'Confirm') + '...' : (confirmLabel || 'Confirm') }}</button>
      </div>
    </div>
  </div>
</template>
