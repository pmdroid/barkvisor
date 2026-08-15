<script setup lang="ts">
import type { DevicePickOption } from '../utils/deviceCompatibility'
import { DEVICE_LABEL } from '../utils/terminology'

defineProps<{
  modelValue: string
  options: DevicePickOption[]
  disabled?: boolean
}>()

const emit = defineEmits<{ 'update:modelValue': [value: string] }>()

function pick(option: DevicePickOption) {
  if (option.compatible) emit('update:modelValue', option.hostId)
}
</script>

<template>
  <div class="device-picker">
    <label class="device-picker-label">{{ DEVICE_LABEL }}</label>
    <p v-if="options.some((option) => option.recommended)" class="device-picker-hint">
      Recommended {{ DEVICE_LABEL }} is pre-selected. Confirm or pick another {{ DEVICE_LABEL }}.
    </p>
    <div class="device-picker-list" role="radiogroup" :aria-label="DEVICE_LABEL">
      <button
        v-for="option in options"
        :key="option.hostId"
        type="button"
        role="radio"
        class="device-picker-option"
        :class="{
          selected: modelValue === option.hostId,
          disabled: !option.compatible || disabled,
        }"
        :aria-checked="modelValue === option.hostId"
        :disabled="!option.compatible || disabled"
        @click="pick(option)"
      >
        <div class="device-picker-top">
          <span class="device-picker-name">{{ option.label }}</span>
          <span v-if="option.recommended" class="device-chip recommended">Recommended</span>
          <span v-if="option.role === 'self'" class="device-chip self">This {{ DEVICE_LABEL }}</span>
          <span v-else class="device-chip">{{ DEVICE_LABEL }}</span>
        </div>
        <div class="device-picker-meta">
          <span v-if="option.platformLine">{{ option.platformLine }}</span>
          <span :class="option.reachable ? 'ok' : 'down'">
            {{ option.reachable ? 'Reachable' : 'Unreachable' }}
          </span>
        </div>
        <p v-if="option.recommended && option.recommendReasons?.length" class="device-picker-reason recommend">
          {{ option.recommendReasons[0] }}
        </p>
        <p v-else-if="!option.compatible && option.reasons.length" class="device-picker-reason">
          {{ option.reasons[0] }}
        </p>
      </button>
    </div>
  </div>
</template>

<style scoped>
.device-picker {
  margin-bottom: 16px;
}
.device-picker-label {
  display: block;
  font-size: 12px;
  font-weight: 600;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.03em;
  margin-bottom: 8px;
}
.device-picker-hint {
  margin: -2px 0 10px;
  font-size: 12px;
  color: var(--text-secondary);
}
.device-picker-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.device-picker-option {
  text-align: left;
  width: 100%;
  padding: 10px 12px;
  border: 2px solid var(--border);
  border-radius: var(--radius);
  background: transparent;
  color: inherit;
  cursor: pointer;
  font: inherit;
}
.device-picker-option.selected {
  border-color: var(--accent);
  background: rgba(99, 102, 241, 0.08);
}
.device-picker-option.disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.device-picker-top {
  display: flex;
  align-items: center;
  gap: 8px;
}
.device-picker-name {
  font-weight: 600;
  font-size: 13px;
}
.device-picker-meta {
  display: flex;
  gap: 10px;
  margin-top: 4px;
  font-size: 12px;
  color: var(--text-dim);
}
.device-picker-meta .ok { color: var(--text-secondary); }
.device-picker-meta .down { color: var(--red, #ef4444); }
.device-picker-reason {
  margin: 6px 0 0;
  font-size: 12px;
  color: var(--text-secondary);
}
.device-chip {
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  padding: 2px 6px;
  border-radius: 999px;
  border: 1px solid var(--border);
  color: var(--text-dim);
}
.device-chip.self {
  border-color: var(--accent);
  color: var(--accent);
}
.device-chip.recommended {
  border-color: var(--accent);
  background: rgba(99, 102, 241, 0.12);
  color: var(--accent);
}
.device-picker-reason.recommend {
  color: var(--text-secondary);
}
</style>
