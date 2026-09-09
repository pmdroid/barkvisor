<script setup lang="ts">
defineProps<{
  name: string
  osType: 'linux' | 'windows'
}>()

const emit = defineEmits<{
  'update:name': [value: string]
  selectOS: [os: 'linux' | 'windows']
  next: []
}>()
</script>

<template>
  <div>
    <h3 class="step-title">Basics</h3>
    <div class="form-group">
      <label>VM Name</label>
      <input
        :value="name"
        placeholder="my-vm"
        autofocus
        @input="emit('update:name', ($event.target as HTMLInputElement).value)"
        @keyup.enter="emit('next')"
      />
    </div>
    <div class="form-group">
      <label>OS Type</label>
      <div class="os-grid">
        <div class="os-card" :class="{ selected: osType === 'linux' }" @click="emit('selectOS', 'linux')">
          <span style="font-size:24px">&#x1f427;</span>
          <span>Linux</span>
        </div>
        <div
          class="os-card"
          :class="{ selected: osType === 'windows' }"
          @click="emit('selectOS', 'windows')"
        >
          <span style="font-size:24px">&#x1fa9f;</span>
          <span>Windows</span>
        </div>
        <div class="os-card disabled">
          <span style="font-size:24px">&#x1f34e;</span>
          <span>macOS</span>
          <span class="os-soon">soon</span>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.step-title {
  font-size: 15px;
  font-weight: 600;
  margin-bottom: 16px;
  color: var(--text);
}
.os-grid {
  display: flex;
  gap: 10px;
}
.os-card {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
  padding: 16px 8px;
  border: 2px solid var(--border);
  border-radius: var(--radius);
  cursor: pointer;
  transition: all 0.15s;
  position: relative;
  font-size: 13px;
  font-weight: 500;
}
.os-card:hover:not(.disabled) { border-color: var(--accent); }
.os-card.selected {
  border-color: var(--accent);
  background: rgba(99, 102, 241, 0.08);
}
.os-card.disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
.os-soon {
  position: absolute;
  top: 4px;
  right: 6px;
  font-size: 9px;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.05em;
}
</style>
