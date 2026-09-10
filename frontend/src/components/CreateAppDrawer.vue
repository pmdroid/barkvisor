<script setup lang="ts">
import { computed, ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import { useDevicesStore } from '../stores/devices'
import { useToastStore } from '../stores/toast'
import { useFeature } from '../composables/useFeature'
import { devicePath, isSelfDevice } from '../utils/homeDeviceApi'
import { DEVICE_LABEL } from '../utils/terminology'
import AppButton from './ui/AppButton.vue'

const props = defineProps<{ initialHostId?: string }>()
const emit = defineEmits(['close', 'created'])

const devices = useDevicesStore()
const toast = useToastStore()
const docker = useFeature('dockerEngine')

const defaultYaml = `apiVersion: barkvisor.dev/v1
kind: Application
metadata:
  name: whoami
spec:
  runtime: device
  compose: |
    services:
      whoami:
        image: traefik/whoami
        ports:
          - "8080:80"
        restart: unless-stopped
`

const yaml = ref(defaultYaml)
const hostId = ref(props.initialHostId || devices.selfDevice?.hostId || '')
const submitting = ref(false)
const error = ref('')

const selected = computed(() => devices.deviceByHostId(hostId.value) || devices.selfDevice)

const dockerBlocked = computed(() => {
  if (!isSelfDevice(selected.value || { hostId: '', role: 'self' })) return ''
  if (docker.available) return ''
  return docker.explanation || 'This Device does not have dockerEngine.'
})

async function submit() {
  error.value = ''
  const device = selected.value
  if (!device) {
    error.value = `Pick a ${DEVICE_LABEL}.`
    return
  }
  submitting.value = true
  try {
    await api.post(devicePath(device, '/workloads/apply'), yaml.value, {
      headers: { 'Content-Type': 'application/yaml' },
    })
    toast.success('App applied')
    emit('created')
  } catch (e: unknown) {
    error.value = apiErrorMessage(e)
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <div class="mag-overlay" @click.self="emit('close')">
    <div class="mag-frame">
      <div class="mag-head">
        <h2>Create App</h2>
      </div>
      <div class="mag-body">
        <label class="field">
          <span>{{ DEVICE_LABEL }}</span>
          <select v-model="hostId">
            <option
              v-for="row in devices.devices"
              :key="row.hostId"
              :value="row.hostId"
            >{{ devices.deviceLabel(row) }}</option>
          </select>
        </label>
        <p v-if="dockerBlocked" class="warn">{{ dockerBlocked }}</p>
        <label class="field">
          <span>Workload spec</span>
          <textarea v-model="yaml" spellcheck="false" />
        </label>
        <p v-if="error" class="err">{{ error }}</p>
      </div>
      <div class="mag-foot">
        <AppButton @click="emit('close')">Cancel</AppButton>
        <AppButton variant="primary" :disabled="submitting" @click="submit">
          {{ submitting ? 'Applying…' : 'Apply' }}
        </AppButton>
      </div>
    </div>
  </div>
</template>

<style scoped>
.mag-overlay {
  position: fixed;
  inset: 0;
  background: var(--modal-overlay-bg);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 20;
  padding: 24px;
}
.mag-frame {
  width: 720px;
  max-width: 100%;
  max-height: 90vh;
  background: var(--modal-surface);
  border: 1px solid var(--border);
  border-radius: 2px;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  box-shadow: var(--shadow-lg);
}
.mag-head {
  padding: 18px 22px 12px;
  border-bottom: 1px solid var(--border);
}
.mag-head h2 {
  font-size: 17px;
  font-weight: 700;
  margin: 0;
}
.mag-body {
  padding: 16px 22px;
  overflow: auto;
  flex: 1;
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-bottom: 12px;
  font-size: 13px;
}
.field textarea,
.field select {
  background: var(--bg-input);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 2px;
  padding: 8px 10px;
}
.field textarea {
  min-height: 280px;
  font-family: var(--font-mono);
  font-size: 12px;
  line-height: 1.45;
}
.warn { color: var(--amber); font-size: 13px; }
.err { color: var(--red); font-size: 13px; }
.mag-foot {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  padding: 12px 16px;
}
</style>
