<script setup lang="ts">
import { ref, watch } from 'vue'
import AppSelect from '../ui/AppSelect.vue'
import UnsupportedHint from '../ui/UnsupportedHint.vue'

const props = defineProps<{
  guestArch: string
  archOptions: Array<{ value: string; label: string; disabled?: boolean }>
  machineType: string
  accelerator: string
  cpuModel: string
  uefi: boolean
  tpmEnabled: boolean
  alwaysShow: boolean
  archProblem: string | null
}>()

const emit = defineEmits<{
  'update:guestArch': [value: string]
  'update:uefi': [value: boolean]
  'update:tpmEnabled': [value: boolean]
  'update:alwaysShow': [value: boolean]
}>()

const open = ref(props.alwaysShow || !!props.archProblem)

watch(
  () => [props.alwaysShow, props.archProblem] as const,
  ([always, problem]) => {
    if (always || problem) open.value = true
  },
)
</script>

<template>
  <details class="arch-details" :open="open" @toggle="open = ($event.target as HTMLDetailsElement).open">
    <summary class="arch-summary">Architecture details</summary>
    <div class="arch-body">
      <p class="arch-lede">
        BarkVisor uses the image architecture. Change these only if you know you need a different architecture or firmware.
      </p>
      <div class="form-group">
        <label>Architecture</label>
        <AppSelect
          :modelValue="guestArch"
          :options="archOptions"
          @update:modelValue="emit('update:guestArch', $event)"
        />
        <UnsupportedHint v-if="archProblem" :text="archProblem" />
      </div>
      <div class="arch-inspect">
        <div>
          <span class="arch-inspect-label">Machine</span>
          <span class="mono">{{ machineType }}</span>
        </div>
        <div>
          <span class="arch-inspect-label">Accelerator</span>
          <span class="mono">{{ accelerator || 'host default' }}</span>
        </div>
        <div>
          <span class="arch-inspect-label">CPU model</span>
          <span class="mono">{{ cpuModel }}</span>
        </div>
      </div>
      <label class="arch-check">
        <input
          type="checkbox"
          :checked="uefi"
          @change="emit('update:uefi', ($event.target as HTMLInputElement).checked)"
        />
        UEFI firmware
      </label>
      <label class="arch-check">
        <input
          type="checkbox"
          :checked="tpmEnabled"
          @change="emit('update:tpmEnabled', ($event.target as HTMLInputElement).checked)"
        />
        TPM 2.0
      </label>
      <label class="arch-check">
        <input
          type="checkbox"
          :checked="alwaysShow"
          @change="emit('update:alwaysShow', ($event.target as HTMLInputElement).checked)"
        />
        Always show architecture details
      </label>
    </div>
  </details>
</template>

<style scoped>
.arch-details {
  margin-top: 16px;
  border-top: 1px solid var(--border-subtle);
  padding-top: 12px;
}
.arch-summary {
  cursor: pointer;
  font-size: 13px;
  font-weight: 600;
  color: var(--text-dim);
  list-style: none;
}
.arch-summary::-webkit-details-marker {
  display: none;
}
.arch-summary::before {
  content: '▸ ';
  display: inline-block;
  transition: transform 0.15s;
}
.arch-details[open] .arch-summary::before {
  transform: rotate(90deg);
}
.arch-body {
  margin-top: 12px;
}
.arch-lede {
  font-size: 12px;
  color: var(--text-dim);
  line-height: 1.45;
  margin: 0 0 12px;
}
.arch-inspect {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
  margin: 0 0 12px;
  font-size: 12px;
}
.arch-inspect-label {
  display: block;
  font-weight: 600;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.03em;
  font-size: 10px;
  margin-bottom: 2px;
}
.arch-check {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 13px;
  margin: 8px 0;
  cursor: pointer;
}
.mono {
  font-family: var(--font-mono);
}
</style>
