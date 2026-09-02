<script setup lang="ts">
import { computed } from 'vue'
import type { HostInterface } from '../api/types'
import {
  addAdditionalAddress,
  addressRowLabel,
  applyDhcpToggle,
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
const dhcpEnabled = computed(() => props.modelValue.some((r) => r.kind === 'dhcp'))
const dhcpRow = computed(() => props.modelValue.find((r) => r.kind === 'dhcp'))
const primaryRow = computed(() => props.modelValue.find((r) => r.kind === 'primary'))
const additionalRows = computed(() => props.modelValue.filter((r) => r.kind === 'additional'))
const primaryCidr = computed(() => dhcpEnabled.value ? (dhcpRow.value?.cidr ?? '') : (primaryRow.value?.cidr ?? ''))
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
  emit('update:modelValue', props.modelValue.filter((r) => r.id !== id))
}

function toggleDHCP(enabled: boolean) {
  emit('update:modelValue', applyDhcpToggle(props.modelValue, enabled))
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

    <label class="dhcp-row">
      <input
        type="checkbox"
        :checked="dhcpEnabled"
        :disabled="locked"
        @change="toggleDHCP(($event.target as HTMLInputElement).checked)"
      >
      <span>Use DHCP for primary address</span>
    </label>

    <div v-if="dhcpEnabled || primaryRow" class="address-row">
      <span class="row-label">{{ addressRowLabel('primary', dhcpEnabled) }}</span>
      <input
        :value="primaryCidr"
        placeholder="192.168.1.10/24"
        :disabled="locked || dhcpEnabled"
        @input="primaryRow && updateRow(primaryRow.id, { cidr: ($event.target as HTMLInputElement).value })"
      >
    </div>

    <div v-for="row in additionalRows" :key="row.id" class="address-row">
      <span class="row-label">{{ addressRowLabel('additional', dhcpEnabled) }}</span>
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

    <p v-if="!dhcpEnabled" class="hint">
      Static primary needs a gateway below. Extra rows are additional IPs on the same interface (Linux and macOS).
    </p>
    <p v-else class="hint">
      DHCP supplies the primary IP. Add rows below for extra addresses on the same interface.
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
