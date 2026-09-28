<script setup lang="ts">
import type { PortForwardRule } from '../api/types'
import { applyPortForwardBind, type BindableRule, type BindField } from '../utils/portForwardBind'
import AppSelect from './ui/AppSelect.vue'

const props = withDefaults(defineProps<{ bindField?: BindField }>(), { bindField: 'host' })
const model = defineModel<BindableRule[]>({ default: () => [] })

function addRule() {
  model.value = [...model.value, { protocol: 'tcp', hostPort: 0, guestPort: 0 }]
}

function removeRule(index: number) {
  model.value = model.value.filter((_, i) => i !== index)
}

function updateRule(index: number, field: keyof PortForwardRule, value: any) {
  const rules = [...model.value]
  rules[index] = { ...rules[index], [field]: value }
  model.value = rules
}

function setBind(index: number, raw: string) {
  const rules = [...model.value]
  rules[index] = applyPortForwardBind(rules[index], props.bindField, raw)
  model.value = rules
}
</script>

<template>
  <div>
    <div v-for="(rule, i) in model" :key="i" style="display:flex;gap:8px;align-items:center;margin-bottom:8px;flex-wrap:wrap">
      <AppSelect :modelValue="rule.protocol" @update:modelValue="updateRule(i, 'protocol', $event)" style="width:80px">
        <option value="tcp">TCP</option>
        <option value="udp">UDP</option>
      </AppSelect>
      <input
        type="text"
        class="mono"
        :value="rule[bindField] ?? ''"
        @input="setBind(i, ($event.target as HTMLInputElement).value)"
        placeholder="Every interface"
        title="Bind address on the Device. Leave empty to publish on every IPv4 interface, or enter an address such as 127.0.0.1."
        spellcheck="false"
        autocomplete="off"
        style="width:150px;font-size:13px"
      />
      <input type="number" :value="rule.hostPort" @input="updateRule(i, 'hostPort', Number(($event.target as HTMLInputElement).value))"
        placeholder="Host port" min="1" max="65535" style="width:100px;font-size:13px" />
      <span style="color:var(--text-dim);font-size:13px">&rarr;</span>
      <input type="number" :value="rule.guestPort" @input="updateRule(i, 'guestPort', Number(($event.target as HTMLInputElement).value))"
        placeholder="Guest port" min="1" max="65535" style="width:100px;font-size:13px" />
      <button class="btn-ghost btn-sm" @click="removeRule(i)" style="padding:2px 8px">&times;</button>
    </div>
    <button class="btn-ghost btn-sm" @click="addRule">+ Add Rule</button>
    <p style="color:var(--text-dim);font-size:11px;margin:6px 0 0">
      Bind address is optional. Empty means the port is published on every IPv4 interface of the Device.
    </p>
  </div>
</template>
