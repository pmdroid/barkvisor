<script setup lang="ts">
defineProps<{
  percent?: number
  indeterminate?: boolean
  label?: string
}>()
</script>

<template>
  <div class="progress-container">
    <div
      class="progress-bar"
      :class="{ 'progress-indeterminate': indeterminate }"
      :style="!indeterminate ? { width: (percent ?? 0) + '%' } : undefined"
    />
    <span class="progress-text">
      <slot>{{ label }}</slot>
    </span>
  </div>
</template>

<style scoped>
.progress-container {
  position: relative;
  height: 20px;
  background: var(--bg);
  border-radius: var(--radius-xs);
  overflow: hidden;
}

.progress-bar {
  height: 100%;
  background: var(--accent);
  opacity: 0.2;
  transition: width 0.3s;
  border-radius: var(--radius-xs);
}

.progress-indeterminate {
  width: 100%;
  animation: progress-indeterminate 1.5s ease-in-out infinite;
  background: linear-gradient(90deg, transparent 0%, var(--accent) 50%, transparent 100%);
  background-size: 200% 100%;
  opacity: 0.15;
}

@keyframes progress-indeterminate {
  0% { background-position: 200% 0; }
  100% { background-position: -200% 0; }
}

.progress-text {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  padding: 0 10px;
  font-size: 11px;
  font-weight: 500;
  color: var(--text-secondary);
}
</style>
