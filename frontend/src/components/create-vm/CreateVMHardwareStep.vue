<script setup lang="ts">
import AppSelect from '../ui/AppSelect.vue'
import CreateVMArchitectureDetails from './CreateVMArchitectureDetails.vue'

const props = defineProps<{
  cpuCount: number
  memoryMB: number
  displayResolution: string
  guestArch: string
  archOptions: Array<{ value: string; label: string; disabled?: boolean }>
  machineType: string
  accelerator: string
  cpuModel: string
  uefi: boolean
  tpmEnabled: boolean
  alwaysShowArchDetails: boolean
  archProblem: string | null
  /** Picked Device logical CPU count (PAS-182). */
  maxCpu: number
  maxMemory: number | null
}>()

const emit = defineEmits<{
  'update:cpuCount': [value: number]
  'update:memoryMB': [value: number]
  'update:displayResolution': [value: string]
  'update:guestArch': [value: string]
  'update:uefi': [value: boolean]
  'update:tpmEnabled': [value: boolean]
  'update:alwaysShowArchDetails': [value: boolean]
}>()

function onCpuInput(raw: string) {
  const n = Number(raw)
  if (!Number.isFinite(n)) return
  const max = props.maxCpu >= 1 ? props.maxCpu : 1
  const clamped = Math.min(Math.max(1, Math.trunc(n)), max)
  emit('update:cpuCount', clamped)
}

function onMemoryInput(raw: string) {
  const n = Number(raw)
  if (!Number.isFinite(n)) return
  const max = props.maxMemory != null && props.maxMemory >= 128 ? props.maxMemory : null
  const clamped = Math.max(128, Math.trunc(n))
  emit('update:memoryMB', max != null ? Math.min(clamped, max) : clamped)
}
</script>

<template>
  <div>
    <h3 class="step-title">Hardware</h3>
    <div style="display:flex;gap:12px">
      <div class="form-group" style="flex:1">
        <label>CPU Cores <span class="hint">(max {{ maxCpu >= 1 ? maxCpu : 1 }})</span></label>
        <input
          :value="cpuCount"
          type="number"
          min="1"
          :max="maxCpu >= 1 ? maxCpu : 1"
          @input="onCpuInput(($event.target as HTMLInputElement).value)"
        />
      </div>
      <div class="form-group" style="flex:1">
        <label>Memory (MB) <span v-if="maxMemory != null && maxMemory >= 128" class="hint">(max {{ maxMemory }})</span></label>
        <input
          :value="memoryMB"
          type="number"
          min="128"
          step="256"
          :max="maxMemory != null && maxMemory >= 128 ? maxMemory : undefined"
          @input="onMemoryInput(($event.target as HTMLInputElement).value)"
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
    <CreateVMArchitectureDetails
      :guestArch="guestArch"
      :archOptions="archOptions"
      :machineType="machineType"
      :accelerator="accelerator"
      :cpuModel="cpuModel"
      :uefi="uefi"
      :tpmEnabled="tpmEnabled"
      :alwaysShow="alwaysShowArchDetails"
      :archProblem="archProblem"
      @update:guestArch="emit('update:guestArch', $event)"
      @update:uefi="emit('update:uefi', $event)"
      @update:tpmEnabled="emit('update:tpmEnabled', $event)"
      @update:alwaysShow="emit('update:alwaysShowArchDetails', $event)"
    />
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
