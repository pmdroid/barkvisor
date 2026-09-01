<script setup lang="ts">
import { computed } from 'vue'
import type { HostInterface } from '../api/types'
import {
  type EditableHostAddress,
  validateAddressList,
} from '../utils/hostInterfaceAddresses'

const props = defineProps<{
  modelValue: EditableHostAddress[]
  iface?: HostInterface | null
  onlyUplink?: boolean
  disabled?: boolean
  l2Only?: boolean
}>()

const emit = defineEmits<{
  'update:modelValue': [EditableHostAddress[]]
}>()

const validation = computed(() => validateAddressList(props.modelValue, { onlyUplink: props.onlyUplink }))
const staticRows = computed(() => props.modelValue.filter((r) => r.kind !== 'dhcp'))
const dhcpEnabled = computed(() => props.modelValue.some((r) => r.kind === 'dhcp'))
const locked = computed(() => props.disabled || props.l2Only)

function rowIndex(id: string): number {
  return props.modelValue.findIndex((r) => r.id === id)
}

function updateRow(id: string, patch: Partial<EditableHostAddress>) {
  const index = rowIndex(id)
  if (index < 0) return
  const next = props.modelValue.map((row, i) => (i === index ? { ...row, ...patch } : row))
  emit('update:modelValue', next)
}

function removeRow(id: string) {
  emit('update:modelValue', props.modelValue.filter((r) => r.id !== id))
}

function addStatic() {
  emit('update:modelValue', [
    ...props.modelValue,
    { id: `static-${Date.now()}`, kind: 'alias', cidr: '' },
  ])
}

function toggleDHCP(enabled: boolean) {
  const without = props.modelValue.filter((r) => r.kind !== 'dhcp')
  emit('update:modelValue', enabled
    ? [{ id: 'dhcp', kind: 'dhcp', cidr: '' }, ...without]
    : without)
}
</script>

<template>
  <div class="host-address-list">
    <div class="host-address-list-head">
      <span class="label">Addresses</span>
      <span v-if="iface?.managedByBarkvisor" class="chip on-host">on host</span>
    </div>

    <label class="dhcp-row">
      <input
        type="checkbox"
        :checked="dhcpEnabled"
        :disabled="locked"
        @change="toggleDHCP(($event.target as HTMLInputElement).checked)"
      >
      <span>DHCP (primary)</span>
    </label>

    <div v-for="row in staticRows" :key="row.id" class="address-row">
      <select
        :value="row.kind"
        :disabled="locked"
        @change="updateRow(row.id, { kind: ($event.target as HTMLSelectElement).value as 'static' | 'alias' })"
      >
        <option value="static">static</option>
        <option value="alias">alias</option>
      </select>
      <input
        :value="row.cidr"
        placeholder="192.168.1.10/24"
        :disabled="locked"
        @input="updateRow(row.id, { cidr: ($event.target as HTMLInputElement).value })"
      >
      <button type="button" class="ghost" :disabled="locked" @click="removeRow(row.id)">
        Remove
      </button>
    </div>

    <button type="button" class="ghost add-btn" :disabled="locked" @click="addStatic">
      + Add address
    </button>
    <p v-if="l2Only" class="l2-hint">L2 only · addresses live on the Bridge</p>

    <ul v-if="validation.errors.length" class="errors">
      <li v-for="err in validation.errors" :key="err">{{ err }}</li>
    </ul>
    <ul v-if="validation.warnings.length" class="warnings">
      <li v-for="warn in validation.warnings" :key="warn">{{ warn }}</li>
    </ul>
  </div>
</template>

<style scoped>
.host-address-list {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.host-address-list-head {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.chip.on-host {
  font-size: 0.75rem;
  padding: 0.1rem 0.45rem;
  border-radius: 999px;
  background: color-mix(in srgb, var(--accent, #3b82f6) 18%, transparent);
}
.dhcp-row, .address-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
}
.address-row input {
  flex: 1;
}
.errors { color: #dc2626; margin: 0; padding-left: 1rem; }
.warnings { color: #b45309; margin: 0; padding-left: 1rem; }
.add-btn { align-self: flex-start; }
.l2-hint {
  margin: 0;
  font-size: 0.8rem;
  color: var(--text-secondary);
}
</style>
