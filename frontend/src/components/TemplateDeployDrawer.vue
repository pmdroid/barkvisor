<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { useTemplateStore } from '../stores/templates'
import { useVMStore } from '../stores/vms'
import { useSSHKeyStore } from '../stores/sshKeys'
import api, { getWSTicket } from '../api/client'
import AppSelect from './ui/AppSelect.vue'
import type { VMTemplate, DeployTemplateRequest, BridgeInfo } from '../api/types'

const props = defineProps<{ template: VMTemplate }>()
const emit = defineEmits(['close', 'deployed'])

const templateStore = useTemplateStore()
const vmStore = useVMStore()
const sshKeyStore = useSSHKeyStore()

const selectedSSHKeyId = ref('')

// Bridge status for bridged templates
const bridgeAvailable = ref<boolean | null>(null) // null = loading
const bridgeChecked = ref(false)

onMounted(async () => {
  sshKeyStore.fetchAll().then(() => {
    if (sshKeyStore.defaultKey) selectedSSHKeyId.value = sshKeyStore.defaultKey.id
  })
  if (props.template.networkMode === 'bridged') {
    try {
      const { data } = await api.get<BridgeInfo[]>('/system/bridges')
      bridgeAvailable.value = data.some(b => b.status === 'active')
    } catch {
      bridgeAvailable.value = false
    }
    bridgeChecked.value = true
  } else {
    bridgeAvailable.value = true
    bridgeChecked.value = true
  }
})

const step = ref(1)
const totalSteps = computed(() => visibleInputs.value.length > 0 ? 3 : 2)

// Step 1: VM Name & Resource overrides
const vmName = ref('')
const cpuCount = ref(props.template.cpuCount)
const memoryMB = ref(props.template.memoryMB)
const diskSizeGB = ref(props.template.diskSizeGB)

// Step 2: Template inputs (dynamic) — ssh_keys is handled by the dedicated SSH key selector
const visibleInputs = computed(() => props.template.inputs.filter(i => i.id !== 'ssh_keys'))
const inputValues = ref<Record<string, string>>({})
for (const input of props.template.inputs) {
  if (input.id === 'ssh_keys') continue
  inputValues.value[input.id] = input.default ?? ''
}

// State
const error = ref('')
const loading = ref(false)

// Download progress state
const phase = ref<'form' | 'downloading' | 'deploying' | 'done'>('form')
const downloadPercent = ref(0)
const downloadStatus = ref('')
let eventSource: EventSource | null = null

onUnmounted(() => {
  eventSource?.close()
})

function canProceed(): boolean {
  if (step.value === 1) return !!vmName.value.trim()
  if (step.value === 2 && visibleInputs.value.length > 0) {
    return visibleInputs.value
      .filter(i => i.required)
      .every(i => {
        const val = inputValues.value[i.id] ?? ''
        if (!val) return false
        if (i.minLength && val.length < i.minLength) return false
        return true
      })
  }
  return true
}

function next() {
  if (canProceed() && step.value < totalSteps.value) step.value++
}

function prev() {
  if (step.value > 1) step.value--
}

function buildRequest(): DeployTemplateRequest {
  const inputs = { ...inputValues.value }
  const selectedKey = sshKeyStore.keys.find(k => k.id === selectedSSHKeyId.value)
  if (selectedKey) {
    inputs.ssh_keys = selectedKey.publicKey
  }
  return {
    templateId: props.template.id,
    vmName: vmName.value.trim(),
    inputs,
    cpuCount: cpuCount.value !== props.template.cpuCount ? cpuCount.value : undefined,
    memoryMB: memoryMB.value !== props.template.memoryMB ? memoryMB.value : undefined,
    diskSizeGB: diskSizeGB.value !== props.template.diskSizeGB ? diskSizeGB.value : undefined,
  }
}

async function watchDownload(imageId: string) {
  phase.value = 'downloading'
  downloadPercent.value = 0
  downloadStatus.value = 'Starting download...'

  let ticket: string
  try {
    ticket = await getWSTicket()
  } catch {
    error.value = 'Failed to obtain connection ticket'
    phase.value = 'form'
    return
  }
  eventSource = new EventSource(`/api/images/${imageId}/progress?ticket=${ticket}`)

  eventSource.onmessage = async (event) => {
    try {
      const data = JSON.parse(event.data)
      if (data.status === 'downloading') {
        downloadPercent.value = data.percent ?? 0
        const mb = Math.round((data.bytesReceived || 0) / 1024 / 1024)
        const totalMb = data.totalBytes ? Math.round(data.totalBytes / 1024 / 1024) : null
        downloadStatus.value = totalMb
          ? `Downloading image... ${mb} / ${totalMb} MB`
          : `Downloading image... ${mb} MB`
      } else if (data.status === 'decompressing') {
        downloadStatus.value = 'Decompressing image...'
        downloadPercent.value = 100
      } else if (data.status === 'ready') {
        eventSource?.close()
        eventSource = null
        // Image is ready — re-deploy to create the VM
        await doDeploy()
      } else if (data.status === 'error') {
        eventSource?.close()
        eventSource = null
        error.value = data.error || 'Image download failed'
        phase.value = 'form'
      }
    } catch { /* ignore parse errors */ }
  }

  eventSource.onerror = () => {
    eventSource?.close()
    eventSource = null
    error.value = 'Lost connection to download progress'
    phase.value = 'form'
  }
}

async function doDeploy() {
  phase.value = 'deploying'
  downloadStatus.value = 'Creating VM and starting...'
  error.value = ''

  try {
    const result = await templateStore.deploy(buildRequest())

    if (result.status === 'downloading' && result.imageId) {
      watchDownload(result.imageId)
      return
    }

    if (result.status === 'created' && result.vm) {
      vmStore.vms.push(result.vm)
      phase.value = 'done'
      emit('deployed', result.vm)
    }
  } catch (e: any) {
    error.value = e.response?.data?.reason || e.message
    phase.value = 'form'
  }
}

async function submit() {
  error.value = ''
  loading.value = true
  try {
    const result = await templateStore.deploy(buildRequest())

    if (result.status === 'downloading' && result.imageId) {
      watchDownload(result.imageId)
    } else if (result.status === 'created' && result.vm) {
      vmStore.vms.push(result.vm)
      phase.value = 'done'
      emit('deployed', result.vm)
    }
  } catch (e: any) {
    error.value = e.response?.data?.reason || e.message
  } finally {
    loading.value = false
  }
}
</script>

<template>
  <div class="modal-overlay" @click.self="emit('close')">
    <div class="modal" style="max-width:520px">
      <h2>Deploy {{ template.name }}</h2>
      <p style="color:var(--text-dim);font-size:13px;margin-bottom:16px">{{ template.description }}</p>

      <!-- Bridge not available warning -->
      <div v-if="template.networkMode === 'bridged' && bridgeChecked && !bridgeAvailable" class="bridge-error">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="flex-shrink:0">
          <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
        </svg>
        <div>
          <strong>Bridged networking required</strong>
          <p style="margin:4px 0 0;font-size:12px;color:var(--text-secondary)">
            This template requires a bridge network but no active bridge was found.
            Install the BarkVisor Helper and enable a bridge under <strong>Settings &rarr; Network</strong>.
          </p>
        </div>
      </div>

      <!-- Downloading / Deploying phase -->
      <div v-if="phase === 'downloading' || phase === 'deploying'" style="padding:24px 0">
        <div style="text-align:center;margin-bottom:16px">
          <div style="font-size:14px;font-weight:500;margin-bottom:8px">
            {{ phase === 'downloading' ? 'Downloading Image' : 'Deploying VM' }}
          </div>
          <div style="font-size:13px;color:var(--text-dim)">{{ downloadStatus }}</div>
        </div>
        <div class="progress-bar-track">
          <div class="progress-bar-fill"
            :style="{ width: phase === 'deploying' ? '100%' : downloadPercent + '%' }"
            :class="{ indeterminate: phase === 'deploying' }" />
        </div>
        <div v-if="phase === 'downloading'" style="text-align:center;margin-top:8px;font-size:12px;color:var(--text-dim)">
          {{ downloadPercent }}%
        </div>
        <div v-if="error" class="error-box" style="margin-top:16px">{{ error }}</div>
      </div>

      <!-- Form phase -->
      <template v-else-if="phase === 'form'">
        <!-- Step indicator -->
        <div class="wizard-steps">
          <template v-for="s in totalSteps" :key="s">
            <div v-if="s > 1" class="wizard-line" :class="{ done: s <= step }" />
            <button class="wizard-dot"
              :class="{ active: s === step, done: s < step }"
              :disabled="s > step"
              @click="s < step ? step = s : null">
              <svg v-if="s < step" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"><polyline points="20 6 9 17 4 12"/></svg>
              <span v-else>{{ s }}</span>
            </button>
          </template>
        </div>

        <!-- Step 1: Name & Resources -->
        <div v-if="step === 1">
          <h3 class="step-title">VM Name & Resources</h3>
          <div class="form-group">
            <label>VM Name</label>
            <input v-model="vmName" :placeholder="`my-${template.slug}`" @keyup.enter="next" autofocus />
          </div>
          <div style="display:flex;gap:12px">
            <div class="form-group" style="flex:1">
              <label>CPU Cores</label>
              <input v-model.number="cpuCount" type="number" min="1" max="16" />
            </div>
            <div class="form-group" style="flex:1">
              <label>Memory (MB)</label>
              <input v-model.number="memoryMB" type="number" min="128" step="256" />
            </div>
          </div>
          <div class="form-group">
            <label>Disk Size (GB)</label>
            <input v-model.number="diskSizeGB" type="number" min="1" />
          </div>
          <div class="form-group">
            <label>SSH Key</label>
            <AppSelect v-model="selectedSSHKeyId">
              <option value="">None</option>
              <option v-for="sk in sshKeyStore.keys" :key="sk.id" :value="sk.id">
                {{ sk.name }}
              </option>
            </AppSelect>
            <div v-if="sshKeyStore.keys.length === 0" style="margin-top:6px;font-size:12px;color:var(--text-dim)">
              No SSH keys stored yet. Add keys in Settings first.
            </div>
          </div>
          <div style="display:flex;gap:8px;align-items:center;margin-top:4px;font-size:12px;color:var(--text-dim)">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
              <path v-if="template.networkMode === 'bridged'" d="M9 2H5a2 2 0 00-2 2v4m6-6h10a2 2 0 012 2v4M9 2v6m12-2H9m12 0v12a2 2 0 01-2 2H9m12-14H9m0 14H5a2 2 0 01-2-2V8m6 14V8m0 0H3" />
              <path v-else d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
            </svg>
            Network: <strong>{{ template.networkMode === 'bridged' ? 'Bridged' : 'NAT' }}</strong>
            <span v-if="template.networkMode === 'bridged'" style="color:var(--text-dim)">(gets its own IP on your LAN)</span>
          </div>
          <div v-if="template.portForwards && template.portForwards.length > 0 && template.networkMode !== 'bridged'" style="margin-top:12px">
            <label style="font-size:12px;color:var(--text-dim)">Port Forwards (auto-configured)</label>
            <div v-for="pf in template.portForwards" :key="`${pf.hostPort}-${pf.guestPort}`"
              style="font-size:12px;color:var(--text-dim);padding:2px 0">
              {{ pf.protocol.toUpperCase() }} host:{{ pf.hostPort }} &rarr; guest:{{ pf.guestPort }}
            </div>
          </div>
        </div>

        <!-- Step 2: Template inputs (dynamic) -->
        <div v-if="step === 2 && visibleInputs.length > 0">
          <h3 class="step-title">Configuration</h3>
          <div v-for="input in visibleInputs" :key="input.id" class="form-group">
            <label>
              {{ input.label }}
              <span v-if="input.required" style="color:var(--danger)">*</span>
            </label>
            <textarea
              v-if="input.type === 'textarea'"
              v-model="inputValues[input.id]"
              :placeholder="input.placeholder"
              rows="3"
            />
            <input
              v-else
              v-model="inputValues[input.id]"
              :type="input.type"
              :placeholder="input.placeholder"
            />
            <span v-if="input.minLength" style="font-size:11px;color:var(--text-dim);display:block;margin-top:2px">
              Minimum {{ input.minLength }} characters
            </span>
          </div>
        </div>

        <!-- Review step (last step) -->
        <div v-if="step === totalSteps">
          <h3 class="step-title">Review</h3>
          <div style="font-size:13px;line-height:1.8">
            <div><strong>Template:</strong> {{ template.name }}</div>
            <div><strong>VM Name:</strong> {{ vmName }}</div>
            <div><strong>CPU:</strong> {{ cpuCount }} cores</div>
            <div><strong>Memory:</strong> {{ memoryMB }} MB</div>
            <div><strong>Disk:</strong> {{ diskSizeGB }} GB</div>
            <div><strong>Network:</strong> {{ template.networkMode === 'bridged' ? 'Bridged' : 'NAT' }}</div>
            <div><strong>SSH Key:</strong> {{ sshKeyStore.keys.find(k => k.id === selectedSSHKeyId)?.name || 'None' }}</div>
            <div><strong>Image:</strong> {{ template.imageSlug }}</div>
          </div>
        </div>

        <div v-if="error" class="error-box">{{ error }}</div>

        <div style="display:flex;justify-content:space-between;margin-top:20px">
          <button v-if="step > 1" class="btn-ghost" @click="prev">Back</button>
          <span v-else />
          <button v-if="step < totalSteps" class="btn-primary" :disabled="!canProceed()" @click="next">
            Next
          </button>
          <button v-else class="btn-primary" :disabled="!canProceed() || loading || (template.networkMode === 'bridged' && !bridgeAvailable)" @click="submit">
            {{ loading ? 'Deploying...' : 'Deploy' }}
          </button>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped>
.wizard-steps {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 0;
  margin-bottom: 20px;
}
.wizard-dot {
  width: 28px;
  height: 28px;
  border-radius: 2px;
  border: 2px solid var(--border);
  background: transparent;
  color: var(--text-dim);
  font-size: 12px;
  font-weight: 600;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: default;
  transition: all 0.2s;
  padding: 0;
  flex-shrink: 0;
}
.wizard-dot.active {
  border-color: var(--accent);
  background: var(--accent);
  color: #fff;
}
.wizard-dot.done {
  border-color: var(--accent);
  background: var(--accent);
  color: #fff;
  cursor: pointer;
}
.wizard-dot:disabled {
  opacity: 0.5;
  cursor: default;
}
.wizard-line {
  height: 2px;
  width: 40px;
  background: var(--border);
  flex-shrink: 0;
  transition: background 0.2s;
}
.wizard-line.done {
  background: var(--accent);
}
.step-title {
  font-size: 14px;
  font-weight: 600;
  margin-bottom: 14px;
}
.progress-bar-track {
  height: 4px;
  background: var(--bg-hover);
  border-radius: 2px;
  overflow: hidden;
}
.progress-bar-fill {
  height: 100%;
  background: var(--primary);
  border-radius: 2px;
  transition: width 0.3s ease;
}
.progress-bar-fill.indeterminate {
  width: 100% !important;
  animation: indeterminate 1.5s ease-in-out infinite;
  background: linear-gradient(90deg, var(--primary) 0%, var(--primary) 40%, transparent 40%, transparent 60%, var(--primary) 60%);
  background-size: 200% 100%;
}
@keyframes indeterminate {
  0% { background-position: 100% 0; }
  100% { background-position: -100% 0; }
}
.bridge-error {
  display: flex;
  gap: 10px;
  align-items: flex-start;
  padding: 12px 14px;
  background: rgba(239, 68, 68, 0.08);
  border: 1px solid rgba(239, 68, 68, 0.25);
  border-radius: var(--radius-sm);
  margin-bottom: 16px;
  font-size: 13px;
  color: var(--red, #ef4444);
}
</style>
