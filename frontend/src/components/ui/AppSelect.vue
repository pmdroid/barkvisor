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
  display: inline-flex;
  align-items: center;
  min-width: 140px;
  vertical-align: middle;
}

.app-select select {
  appearance: none;
  -webkit-appearance: none;
  box-sizing: border-box;
  background: var(--bg-input);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  height: var(--control-h);
  padding: 0 28px 0 10px;
  font-family: inherit;
  font-size: 12.5px;
  font-weight: 600;
  color: var(--text);
  cursor: pointer;
  width: 100%;
}

.app-select select:hover {
  background: var(--bg-hover);
  border-color: var(--border);
}

.app-select select:focus {
  border-color: var(--accent);
  box-shadow: 0 0 0 2px var(--accent-muted);
  outline: none;
}

.app-select select:disabled {
  opacity: 0.4;
  pointer-events: none;
}

.app-select-sm select {
  height: var(--control-h-sm);
  padding: 0 28px 0 10px;
  font-size: 12.5px;
  border-radius: var(--radius);
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
