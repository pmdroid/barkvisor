<script setup lang="ts">
import type { PortForwardRule } from '../api/types'
import { applyPortForwardBind, portForwardBind, type BindableRule, type BindField } from '../utils/portForwardBind'
import AppSelect from './ui/AppSelect.vue'

const props = withDefaults(defineProps<{ bindField?: BindField }>(), { bindField: 'host' })
const model = defineModel<BindableRule[]>({ default: () => [] })

// The binds each rule was opened with. This modal is created fresh per open,
// so this snapshot is the state the operator started from, and emptying a box
// can fall back to it instead of silently widening the publish.
const openedBinds = model.value.map((rule) => portForwardBind(rule, props.bindField))

function addRule() {
  model.value = [...model.value, { protocol: 'tcp', hostPort: 0, guestPort: 0 }]
  openedBinds.push('')
}

function removeRule(index: number) {
  model.value = model.value.filter((_, i) => i !== index)
  openedBinds.splice(index, 1)
}

function updateRule(index: number, field: keyof PortForwardRule, value: any) {
  const rules = [...model.value]
  rules[index] = { ...rules[index], [field]: value }
  model.value = rules
}

function setBind(index: number, raw: string) {
  const rules = [...model.value]
  rules[index] = applyPortForwardBind(rules[index], props.bindField, raw, openedBinds[index])
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
        title="Bind address on the Device. Empty publishes on every IPv4 interface. To widen a bind that is already set, type 0.0.0.0."
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
      To widen an existing bind, type <span class="mono">0.0.0.0</span> — clearing the box keeps the current bind.
    </p>
  </div>
</template>
