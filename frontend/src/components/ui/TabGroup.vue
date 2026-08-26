<script setup lang="ts">
defineProps<{
  modelValue: string | null
  tabs: Array<{ key: string; label: string; count?: number }>
}>()

defineEmits<{ 'update:modelValue': [value: string] }>()
</script>

<template>
  <div class="tab-group">
    <button
      v-for="tab in tabs"
      :key="tab.key"
      :class="{ active: modelValue === tab.key }"
      @click="$emit('update:modelValue', tab.key)"
    >
      {{ tab.label }}
      <span v-if="tab.count != null" class="tab-count">{{ tab.count }}</span>
    </button>
  </div>
</template>

<style scoped>
.tab-group {
  display: flex;
  gap: 2px;
  background: transparent;
  border: 0;
  border-radius: 0;
  padding: 0;
  width: fit-content;
}

.tab-group button {
  box-sizing: border-box;
  height: var(--control-h);
  padding: 0 12px;
  border: 1px solid var(--line);
  background: transparent;
  color: var(--text-dim);
  font-size: 12.5px;
  font-weight: 600;
  border-radius: var(--radius);
  cursor: pointer;
  transition: all 0.15s;
  display: flex;
  align-items: center;
  gap: 6px;
}

.tab-group button:hover:not(.active) {
  color: var(--text-secondary);
  background: var(--bg-hover);
}

.tab-group button.active {
  background: transparent;
  color: var(--text);
  border-color: var(--accent);
}

.tab-count {
  font-size: 10px;
  background: var(--bg-hover);
  padding: 1px 6px;
  border-radius: 2px;
  font-weight: 600;
}

.tab-group button.active .tab-count {
  background: rgba(0, 144, 248, 0.2);
}
</style>
