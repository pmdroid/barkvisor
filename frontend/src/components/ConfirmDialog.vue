<script setup lang="ts">
const props = defineProps<{
  title: string
  message: string
  confirmLabel?: string
  danger?: boolean
  loading?: boolean
  details?: string[]
}>()
const emit = defineEmits(['confirm', 'cancel'])
</script>

<template>
  <div class="modal-overlay" @click.self="!loading && emit('cancel')">
    <div class="split-frame split-narrow">
      <section class="split-stage">
        <div class="split-head">
          <h2>{{ title }}</h2>
        </div>
        <div class="split-body">
          <p class="split-warn">{{ message }}</p>
          <details v-if="props.details?.length" class="split-details">
            <summary>Changes</summary>
            <ul>
              <li v-for="item in props.details" :key="item">{{ item }}</li>
            </ul>
          </details>
        </div>
        <div class="split-foot">
          <button class="btn-ghost" :disabled="loading" @click="emit('cancel')">Cancel</button>
          <button
            :class="danger ? 'btn-danger' : 'btn-primary'"
            :disabled="loading"
            @click="emit('confirm')"
          >{{ loading ? (confirmLabel || 'Confirm') + '...' : (confirmLabel || 'Confirm') }}</button>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.split-warn {
  color: var(--amber);
  font-size: 13px;
  line-height: 1.5;
  padding: 12px 0;
  margin: 0;
}
.split-details {
  margin: 0 0 8px;
  font-size: 13px;
  color: var(--text-secondary);
}
.split-details summary {
  cursor: pointer;
  font-weight: 600;
  margin-bottom: 6px;
}
.split-details ul {
  margin: 0;
  padding-left: 18px;
}
</style>
