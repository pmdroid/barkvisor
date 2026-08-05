<script setup lang="ts">
import { computed } from 'vue'
import AppSelect from '../ui/AppSelect.vue'
import { useCapabilitiesStore } from '../../stores/capabilities'

defineProps<{
  cpuCount: number
  memoryMB: number
  displayResolution: string
}>()

const emit = defineEmits<{
  'update:cpuCount': [value: number]
  'update:memoryMB': [value: number]
  'update:displayResolution': [value: string]
}>()

const caps = useCapabilitiesStore()
const maxCpu = computed(() => caps.hostCpuCount)

function onCpuInput(raw: string) {
  const n = Number(raw)
  if (!Number.isFinite(n)) return
  const clamped = Math.min(Math.max(1, Math.trunc(n)), maxCpu.value)
  emit('update:cpuCount', clamped)
}
</script>

<template>
  <div>
    <h3 class="step-title">Hardware</h3>
    <div style="display:flex;gap:12px">
      <div class="form-group" style="flex:1">
        <label>CPU Cores <span class="hint">(max {{ maxCpu }})</span></label>
        <input
          :value="cpuCount"
          type="number"
          min="1"
          :max="maxCpu"
          @input="onCpuInput(($event.target as HTMLInputElement).value)"
        />
      </div>
      <div class="form-group" style="flex:1">
        <label>Memory (MB)</label>
        <input
          :value="memoryMB"
          type="number"
          min="128"
          step="256"
          @input="emit('update:memoryMB', Number(($event.target as HTMLInputElement).value))"
        />
      </div>
    </div>
    <div class="form-group">
      <label>Display Resolution</label>
      <AppSelect
        :modelValue="displayResolution"
        @update:modelValue="emit('update:displayResolution', $event as string)"
      >
        <option value="1024x768">1024x768</option>
        <option value="1280x800">1280x800</option>
        <option value="1280x1024">1280x1024</option>
        <option value="1920x1080">1920x1080</option>
      </AppSelect>
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
.hint {
  font-weight: 400;
  font-size: 12px;
  color: var(--text-dim, var(--text-secondary));
}
</style>
