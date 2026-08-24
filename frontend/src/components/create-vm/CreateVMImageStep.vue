<script setup lang="ts">
import AppSelect from '../ui/AppSelect.vue'
import CloudInitEditor from '../CloudInitEditor.vue'
import type { Image, SSHKey } from '../../api/types'
import type { OpenAIPreset } from '../../utils/codingAgentImage'
import { HOME_OLLAMA_GRANT_URL } from '../../utils/codingAgentImage'

defineProps<{
  osType: 'linux' | 'windows'
  mode: 'iso' | 'cloud'
  selectedImageId: string
  selectedSSHKeyId: string
  showCloudInit: boolean
  cloudUserData: string
  filteredImages: Array<Image & { libraryKey?: string }>
  sshKeys: SSHKey[]
  formatBytes: (b: number) => string
  isCodingAgentSelected?: boolean
  openaiPreset?: OpenAIPreset
  byoOpenAIURL?: string
  byoOpenAIAPIKey?: string
}>()

const emit = defineEmits<{
  'update:mode': [value: 'iso' | 'cloud']
  'update:selectedImageId': [value: string]
  'update:selectedSSHKeyId': [value: string]
  'update:showCloudInit': [value: boolean]
  'update:cloudUserData': [value: string]
  'update:openaiPreset': [value: OpenAIPreset]
  'update:byoOpenAIURL': [value: string]
  'update:byoOpenAIAPIKey': [value: string]
}>()

function setMode(m: 'iso' | 'cloud') {
  emit('update:mode', m)
  emit('update:selectedImageId', '')
}
</script>

<template>
  <div>
    <h3 class="step-title">Image</h3>
    <div style="display:flex;gap:8px;margin-bottom:16px">
      <button
        :class="mode === 'iso' ? 'btn-primary btn-sm' : 'btn-ghost btn-sm'"
        @click="setMode('iso')"
      >
        ISO Installer
      </button>
      <button
        v-if="osType === 'linux'"
        :class="mode === 'cloud' ? 'btn-primary btn-sm' : 'btn-ghost btn-sm'"
        @click="setMode('cloud')"
      >
        Cloud Image
      </button>
    </div>
    <div class="form-group">
      <label>{{ mode === 'iso' ? 'ISO Image' : 'Cloud Image' }}</label>
      <AppSelect
        :modelValue="selectedImageId"
        @update:modelValue="emit('update:selectedImageId', $event as string)"
      >
        <option value="" disabled>Select an image...</option>
        <option
          v-for="img in filteredImages"
          :key="img.libraryKey || img.id"
          :value="img.libraryKey || img.id"
        >
          {{ img.name }}{{ img.arch ? ` (${img.arch})` : '' }}{{ img.sizeBytes ? ` (${formatBytes(img.sizeBytes)})` : '' }}
        </option>
      </AppSelect>
      <div v-if="filteredImages.length === 0" style="margin-top:6px;font-size:12px;color:var(--text-dim)">
        No {{ mode === 'iso' ? 'ISO' : 'cloud' }} images in the Home Library.
        Upload or download one in Images first.
      </div>
    </div>
    <div v-if="mode === 'cloud'" class="form-group">
      <label>SSH Key</label>
      <AppSelect
        :modelValue="selectedSSHKeyId"
        @update:modelValue="emit('update:selectedSSHKeyId', $event as string)"
      >
        <option value="">None</option>
        <option v-for="sk in sshKeys" :key="sk.id" :value="sk.id">
          {{ sk.name }}
        </option>
      </AppSelect>
      <div v-if="sshKeys.length === 0" style="margin-top:6px;font-size:12px;color:var(--text-dim)">
        No SSH keys on Home yet. Add keys in Settings first.
      </div>
    </div>
    <div v-if="mode === 'cloud' && isCodingAgentSelected" class="form-group">
      <label>OPENAI_BASE_URL</label>
      <div class="os-grid">
        <button
          type="button"
          class="preset-card"
          :class="{ selected: openaiPreset === 'home-ollama' || openaiPreset === 'device-ollama' }"
          @click="emit('update:openaiPreset', 'home-ollama')"
        >
          Home Ollama grant
          <span class="preset-hint">{{ HOME_OLLAMA_GRANT_URL }}</span>
        </button>
        <button
          type="button"
          class="preset-card"
          :class="{ selected: openaiPreset === 'byo' }"
          @click="emit('update:openaiPreset', 'byo')"
        >
          Bring your own
          <span class="preset-hint">HTTPS endpoint</span>
        </button>
      </div>
      <template v-if="openaiPreset === 'byo'">
        <input
          :value="byoOpenAIURL"
          placeholder="https://api.example/v1"
          style="margin-top:8px"
          @input="emit('update:byoOpenAIURL', ($event.target as HTMLInputElement).value)"
        />
        <input
          :value="byoOpenAIAPIKey"
          type="password"
          autocomplete="off"
          placeholder="OPENAI_API_KEY"
          style="margin-top:8px"
          @input="emit('update:byoOpenAIAPIKey', ($event.target as HTMLInputElement).value)"
        />
      </template>
      <div style="margin-top:6px;font-size:12px;color:var(--text-dim)">
        Agent class: WAN yes, house no. Presets share this Library image.
      </div>
    </div>
    <div v-if="mode === 'cloud'">
      <button
        class="btn-ghost btn-sm"
        style="margin-top:8px"
        @click="emit('update:showCloudInit', !showCloudInit)"
      >
        {{ showCloudInit ? 'Hide' : 'Show' }} Cloud-Init Configuration
      </button>
      <div v-if="showCloudInit" class="form-group" style="margin-top:8px">
        <CloudInitEditor
          :modelValue="cloudUserData"
          @update:modelValue="emit('update:cloudUserData', $event)"
        />
      </div>
    </div>
  </div>
</template>

<style scoped>
.step-title {
  font-size: 15px;
  font-weight: 600;
  margin-bottom: 16px;
  color: var(--text);
}
.os-grid {
  display: flex;
  gap: 8px;
}
.preset-card {
  flex: 1;
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 10px 8px;
  border: 2px solid var(--border);
  border-radius: var(--radius);
  background: transparent;
  color: var(--text);
  cursor: pointer;
  font-size: 13px;
  font-weight: 500;
  text-align: left;
}
.preset-card.selected {
  border-color: var(--accent);
  background: rgba(99, 102, 241, 0.08);
}
.preset-hint {
  font-size: 11px;
  font-weight: 400;
  color: var(--text-dim);
  font-family: var(--font-mono);
}
</style>
