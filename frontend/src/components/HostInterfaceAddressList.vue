<script setup lang="ts">
import { computed } from 'vue'
import type { HostInterface } from '../api/types'
import {
  addAdditionalAddress,
  addressRowLabel,
  type EditableHostAddress,
  validateAddressList,
} from '../utils/hostInterfaceAddresses'

const props = defineProps<{
  modelValue: EditableHostAddress[]
  iface?: HostInterface | null
  onlyUplink?: boolean
  gateway?: string
  disabled?: boolean
}>()

const emit = defineEmits<{
  'update:modelValue': [EditableHostAddress[]]
}>()

const validation = computed(() => validateAddressList(props.modelValue, {
  onlyUplink: props.onlyUplink,
  gateway: props.gateway,
}))
const dhcpRow = computed(() => props.modelValue.find((r) => r.kind === 'dhcp'))
const additionalRows = computed(() => props.modelValue.filter((r) => r.kind === 'additional'))
const dhcpCidr = computed(() => dhcpRow.value?.cidr ?? '')
const locked = computed(() => props.disabled)

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
  const row = props.modelValue.find((r) => r.id === id)
  if (!row || row.kind === 'dhcp') return
  emit('update:modelValue', props.modelValue.filter((r) => r.id !== id))
}

function addAddress() {
  emit('update:modelValue', addAdditionalAddress(props.modelValue))
}
</script>

<template>
  <div class="host-address-list">
    <div class="host-address-list-head">
      <span class="label">Addresses</span>
      <span v-if="iface?.managedByBarkvisor" class="chip on-host">on host</span>
    </div>

    <div class="address-row">
      <span class="row-label">{{ addressRowLabel('dhcp', true) }}</span>
      <input
        :value="dhcpCidr"
        placeholder="from router"
        disabled
      >
    </div>

    <div v-for="row in additionalRows" :key="row.id" class="address-row">
      <span class="row-label">{{ addressRowLabel('additional', true) }}</span>
      <input
        :value="row.cidr"
        placeholder="192.168.1.20/24"
        :disabled="locked"
        @input="updateRow(row.id, { cidr: ($event.target as HTMLInputElement).value })"
      >
      <button type="button" class="ghost" :disabled="locked" @click="removeRow(row.id)">
        Remove
      </button>
    </div>

    <button type="button" class="ghost add-btn" :disabled="locked" @click="addAddress">
      + Add address
    </button>
    <p class="hint">
      DHCP is always on. Add extra static addresses on this interface.
    </p>

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
.row-label {
  flex: 0 0 9.5rem;
  font-size: 0.8125rem;
  color: var(--text-secondary, #64748b);
}
.address-row input {
  flex: 1;
}
.hint {
  margin: 0;
  font-size: 0.8125rem;
  color: var(--text-secondary, #64748b);
  line-height: 1.4;
}
.errors { color: #dc2626; margin: 0; padding-left: 1rem; }
.warnings { color: #b45309; margin: 0; padding-left: 1rem; }
.add-btn { align-self: flex-start; }
</style>
