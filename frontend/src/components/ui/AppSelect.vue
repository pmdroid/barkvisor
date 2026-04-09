<script setup lang="ts">
defineProps<{
  modelValue: string | number | null | undefined
  options?: Array<{ value: string | number; label: string; disabled?: boolean }>
  placeholder?: string
  size?: 'sm' | 'md'
  disabled?: boolean
}>()

defineEmits<{ 'update:modelValue': [value: string] }>()
</script>

<template>
  <div class="app-select" :class="[size === 'sm' && 'app-select-sm']">
    <select
      :value="modelValue"
      :disabled="disabled"
      @change="$emit('update:modelValue', ($event.target as HTMLSelectElement).value)"
    >
      <option v-if="placeholder" value="" disabled>{{ placeholder }}</option>
      <template v-if="options">
        <option
          v-for="opt in options"
          :key="opt.value"
          :value="opt.value"
          :disabled="opt.disabled"
        >{{ opt.label }}</option>
      </template>
      <slot v-else />
    </select>
    <svg class="app-select-chevron" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><polyline points="6 9 12 15 18 9"/></svg>
  </div>
</template>

<style scoped>
.app-select {
  position: relative;
  display: flex;
  align-items: center;
}

.app-select select {
  appearance: none;
  -webkit-appearance: none;
  background: var(--bg-surface);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius-sm);
  height: 38px;
  padding: 0 34px 0 14px;
  font-family: inherit;
  font-size: 13px;
  font-weight: 600;
  letter-spacing: 0.01em;
  color: var(--text-secondary);
  cursor: pointer;
  backdrop-filter: var(--glass-blur);
  box-shadow: var(--glass-shine);
  transition: all 0.15s;
  width: 100%;
}

.app-select select:hover {
  background: var(--bg-hover);
  border-color: var(--border);
}

.app-select select:focus {
  border-color: var(--accent);
  box-shadow: 0 0 0 2px var(--accent-muted), var(--glass-shine);
  outline: none;
}

.app-select select:disabled {
  opacity: 0.4;
  pointer-events: none;
}

.app-select-sm select {
  height: 28px;
  padding: 0 28px 0 10px;
  font-size: 12px;
  border-radius: var(--radius-xs);
}

.app-select-chevron {
  position: absolute;
  right: 10px;
  pointer-events: none;
  color: var(--text-dim);
}

.app-select-sm .app-select-chevron {
  right: 8px;
}
</style>
