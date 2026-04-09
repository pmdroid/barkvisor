<script setup lang="ts">
import type { PortForwardRule } from '../api/types'
import AppSelect from './ui/AppSelect.vue'

const model = defineModel<PortForwardRule[]>({ default: () => [] })

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
</script>

<template>
  <div>
    <div v-for="(rule, i) in model" :key="i" style="display:flex;gap:8px;align-items:center;margin-bottom:8px">
      <AppSelect :modelValue="rule.protocol" @update:modelValue="updateRule(i, 'protocol', $event)" style="width:80px">
        <option value="tcp">TCP</option>
        <option value="udp">UDP</option>
      </AppSelect>
      <input type="number" :value="rule.hostPort" @input="updateRule(i, 'hostPort', Number(($event.target as HTMLInputElement).value))"
        placeholder="Host port" min="1" max="65535" style="width:100px;font-size:13px" />
      <span style="color:var(--text-dim);font-size:13px">&rarr;</span>
      <input type="number" :value="rule.guestPort" @input="updateRule(i, 'guestPort', Number(($event.target as HTMLInputElement).value))"
        placeholder="Guest port" min="1" max="65535" style="width:100px;font-size:13px" />
      <button class="btn-ghost btn-sm" @click="removeRule(i)" style="padding:2px 8px">&times;</button>
    </div>
    <button class="btn-ghost btn-sm" @click="addRule">+ Add Rule</button>
  </div>
</template>
