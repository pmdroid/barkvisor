<script setup lang="ts">
import DevicePicker from '../DevicePicker.vue'
import type { DevicePickOption } from '../../utils/deviceCompatibility'

defineProps<{
  selectedHostId: string
  deviceOptions: DevicePickOption[]
}>()

const emit = defineEmits<{
  'update:selectedHostId': [value: string]
}>()
</script>

<template>
  <div>
    <h3 class="step-title">Place</h3>
    <DevicePicker
      :model-value="selectedHostId"
      :options="deviceOptions"
      @update:model-value="emit('update:selectedHostId', $event)"
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
</style>
