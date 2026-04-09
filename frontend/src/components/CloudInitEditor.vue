<script setup lang="ts">
import { ref, computed } from 'vue'
import api from '../api/client'

const props = defineProps<{
  modelValue: string
  readonly?: boolean
}>()

const emit = defineEmits(['update:modelValue'])

const showSnippets = ref(false)
const validating = ref(false)
const validationResult = ref<{ valid: boolean; error?: string } | null>(null)

const localValue = computed({
  get: () => props.modelValue,
  set: (v: string) => emit('update:modelValue', v),
})

const snippets = [
  { label: 'Install packages', yaml: 'packages:\n  - curl\n  - git\n  - htop\n' },
  { label: 'Run commands', yaml: 'runcmd:\n  - echo "Hello from cloud-init"\n  - apt-get update -y\n' },
  { label: 'Write file', yaml: 'write_files:\n  - path: /etc/myconfig.conf\n    content: |\n      key=value\n    permissions: "0644"\n' },
  { label: 'Add user', yaml: 'users:\n  - name: deploy\n    groups: sudo\n    shell: /bin/bash\n    sudo: ALL=(ALL) NOPASSWD:ALL\n    ssh_authorized_keys:\n      - ssh-ed25519 AAAA...\n' },
  { label: 'Set hostname', yaml: 'hostname: my-vm\nmanage_etc_hosts: true\n' },
  { label: 'Set timezone', yaml: 'timezone: UTC\n' },
  { label: 'Enable Docker', yaml: 'runcmd:\n  - curl -fsSL https://get.docker.com | sh\n  - systemctl enable --now docker\n' },
  { label: 'Grow filesystem', yaml: 'growpart:\n  mode: auto\n  devices: ["/"]\nresize_rootfs: true\n' },
]

function insertSnippet(yaml: string) {
  const current = localValue.value
  const sep = current && !current.endsWith('\n') ? '\n' : ''
  localValue.value = current + sep + yaml
  showSnippets.value = false
}

async function validate() {
  validating.value = true
  validationResult.value = null
  try {
    const { data } = await api.post('/cloud-init/validate', { userData: localValue.value })
    validationResult.value = data
  } catch (e: any) {
    validationResult.value = { valid: false, error: e.response?.data?.reason || e.message }
  } finally {
    validating.value = false
  }
}

const lineCount = computed(() => {
  const lines = localValue.value.split('\n').length
  return Math.max(lines, 8)
})
</script>

<template>
  <div class="ci-editor">
    <!-- Toolbar -->
    <div class="ci-toolbar">
      <label class="ci-label" style="margin:0">Cloud-Config <span style="font-weight:400;color:var(--text-dim)">(YAML, without #cloud-config header)</span></label>
      <div style="display:flex;gap:6px;align-items:center">
        <button
          class="btn-ghost btn-sm"
          :disabled="readonly || validating || !localValue.trim()"
          @click="validate"
        >{{ validating ? 'Validating...' : 'Validate' }}</button>
        <div style="position:relative">
          <button class="btn-ghost btn-sm" @click="showSnippets = !showSnippets" :disabled="readonly">Snippets</button>
          <div v-if="showSnippets" class="ci-snippets-menu">
            <div v-for="s in snippets" :key="s.label" class="ci-snippet-item" @click="insertSnippet(s.yaml)">
              {{ s.label }}
            </div>
          </div>
        </div>
      </div>
    </div>

    <div class="ci-section">
      <textarea
        :value="localValue"
        @input="localValue = ($event.target as HTMLTextAreaElement).value; validationResult = null"
        :rows="lineCount"
        class="ci-textarea ci-mono"
        placeholder="packages:&#10;  - curl&#10;  - git&#10;&#10;runcmd:&#10;  - echo 'Hello'"
        :readonly="readonly"
        spellcheck="false"
      />
      <div v-if="validationResult" class="ci-validation" :class="validationResult.valid ? 'ci-valid' : 'ci-invalid'">
        <span v-if="validationResult.valid">Valid YAML</span>
        <span v-else>{{ validationResult.error }}</span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.ci-editor {
  border: 1px solid var(--border);
  border-radius: var(--radius);
  overflow: visible;
}
.ci-toolbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 6px 10px;
  background: var(--bg);
  border-bottom: 1px solid var(--border-subtle);
  gap: 8px;
}
.ci-label {
  display: block;
  font-size: 11px;
  font-weight: 600;
  color: var(--text-dim);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.ci-section {
  padding: 10px 12px;
}
.ci-textarea {
  width: 100%;
  resize: vertical;
  min-height: 60px;
  background: var(--bg);
  border: 1px solid var(--border);
  border-radius: var(--radius-xs);
  padding: 8px 10px;
  color: var(--text);
  font-size: 12px;
  line-height: 1.6;
}
.ci-textarea:focus {
  outline: none;
  border-color: var(--accent);
}
.ci-mono {
  font-family: var(--font-mono);
  tab-size: 2;
}
.ci-validation {
  margin-top: 6px;
  padding: 6px 10px;
  border-radius: var(--radius-xs);
  font-size: 12px;
}
.ci-valid {
  background: var(--green-muted, rgba(34,197,94,0.15));
  color: var(--green, #22c55e);
}
.ci-invalid {
  background: var(--red-muted, rgba(239,68,68,0.15));
  color: var(--red, #ef4444);
}
.ci-snippets-menu {
  position: absolute;
  top: 100%;
  right: 0;
  margin-top: 4px;
  background: var(--overlay-deep);
  backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border-glass);
  border-radius: var(--radius);
  box-shadow: var(--shadow-lg);
  z-index: 100;
  min-width: 180px;
  overflow: hidden;
}
.ci-snippet-item {
  padding: 8px 12px;
  font-size: 12px;
  cursor: pointer;
  border-bottom: 1px solid var(--border-subtle);
}
.ci-snippet-item:last-child { border-bottom: none; }
.ci-snippet-item:hover { background: var(--bg-hover); }
</style>
