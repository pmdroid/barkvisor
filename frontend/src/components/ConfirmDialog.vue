<script setup lang="ts">
const props = defineProps<{
  title: string
  message: string
  confirmLabel?: string
  danger?: boolean
  loading?: boolean
  details?: string[]
  commands?: string[]
}>()
const emit = defineEmits(['confirm', 'cancel'])
</script>

<template>
  <div class="modal-overlay stack" @click.self="!loading && emit('cancel')">
    <div class="split-frame split-narrow">
      <section class="split-stage">
        <div class="split-head">
          <h2>{{ title }}</h2>
        </div>
        <div class="split-body">
          <p class="split-warn">{{ message }}</p>
          <p v-if="loading" class="split-warn">Working… the Device may drop for 15s or more. Wait — do not retry.</p>
          <details v-if="props.details?.length" class="split-details" open>
            <summary>Changes</summary>
            <ul>
              <li v-for="item in props.details" :key="item">{{ item }}</li>
            </ul>
          </details>
          <details v-if="props.commands?.length" class="split-details" open>
            <summary>Commands</summary>
            <pre class="split-commands">{{ props.commands.join('\n') }}</pre>
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
.split-commands {
  margin: 0;
  padding: 8px 10px;
  overflow: auto;
  max-height: 12rem;
  font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
  white-space: pre-wrap;
  background: color-mix(in srgb, var(--text, #111) 6%, transparent);
  border-radius: 6px;
}
</style>
