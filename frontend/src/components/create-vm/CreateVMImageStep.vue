<script setup lang="ts">
import AppSelect from '../ui/AppSelect.vue'
import CloudInitEditor from '../CloudInitEditor.vue'
import type { Image, SSHKey } from '../../api/types'

defineProps<{
  osType: 'linux' | 'windows'
  mode: 'iso' | 'cloud'
  selectedImageId: string
  selectedSSHKeyId: string
  showCloudInit: boolean
  cloudUserData: string
  filteredImages: Image[]
  sshKeys: SSHKey[]
  formatBytes: (b: number) => string
}>()

const emit = defineEmits<{
  'update:mode': [value: 'iso' | 'cloud']
  'update:selectedImageId': [value: string]
  'update:selectedSSHKeyId': [value: string]
  'update:showCloudInit': [value: boolean]
  'update:cloudUserData': [value: string]
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
        <option v-for="img in filteredImages" :key="img.id" :value="img.id">
          {{ img.name }}{{ img.sizeBytes ? ` (${formatBytes(img.sizeBytes)})` : '' }}
        </option>
      </AppSelect>
      <div v-if="filteredImages.length === 0" style="margin-top:6px;font-size:12px;color:var(--text-dim)">
        No {{ mode === 'iso' ? 'ISO' : 'cloud' }} images available.
        Upload or download one in the Images section first.
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
        No SSH keys stored yet. Add keys in Settings first.
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
</style>
