<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import AppIcon from './AppIcon.vue'

defineProps<{
  loading?: boolean
  size?: 'sm' | 'md'
}>()

const emit = defineEmits<{ stop: [method: 'acpi' | 'force'] }>()
const open = ref(false)
const el = ref<HTMLElement>()

function select(method: 'acpi' | 'force') {
  open.value = false
  emit('stop', method)
}

function onClickOutside(e: MouseEvent) {
  if (open.value && el.value && !el.value.contains(e.target as Node)) {
    open.value = false
  }
}

onMounted(() => document.addEventListener('click', onClickOutside))
onUnmounted(() => document.removeEventListener('click', onClickOutside))
</script>

<template>
  <div ref="el" class="stop-group">
    <button
      :class="['btn-ghost', size === 'sm' && 'btn-sm', 'stop-main']"
      :disabled="loading"
      @click="select('acpi')"
    >
      {{ loading ? 'Stopping...' : 'Stop' }}
    </button>
    <button
      :class="['btn-ghost', size === 'sm' && 'btn-sm', 'stop-toggle']"
      :disabled="loading"
      @click="open = !open"
    >
      <AppIcon name="chevron-down" :size="10" />
    </button>
    <div v-if="open" class="stop-menu">
      <div class="stop-menu-item" @click="select('acpi')">
        <strong>ACPI Shutdown</strong>
        <span>Send ACPI power button signal</span>
      </div>
      <div class="stop-menu-item stop-menu-danger" @click="select('force')">
        <strong>Force Stop</strong>
        <span>Kill the VM process immediately</span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.stop-group {
  position: relative;
  display: inline-flex;
}
.stop-main {
  border-top-right-radius: 0;
  border-bottom-right-radius: 0;
}
.stop-toggle {
  border-top-left-radius: 0;
  border-bottom-left-radius: 0;
  padding: 5px 6px;
}
.stop-menu {
  position: absolute;
  top: 100%;
  right: 0;
  margin-top: 4px;
  background: var(--overlay-heavy);
  backdrop-filter: blur(20px);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  box-shadow: var(--shadow-lg);
  z-index: 100;
  min-width: 240px;
  overflow: hidden;
}
.stop-menu-item {
  padding: 10px 14px;
  cursor: pointer;
  display: flex;
  flex-direction: column;
  gap: 2px;
  border-bottom: 1px solid var(--border-subtle);
}
.stop-menu-item:last-child { border-bottom: none; }
.stop-menu-item:hover { background: var(--bg-hover); }
.stop-menu-item strong { font-size: 13px; }
.stop-menu-item span { font-size: 11px; color: var(--text-dim); }
.stop-menu-danger strong { color: var(--red); }
</style>
