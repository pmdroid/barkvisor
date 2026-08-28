<script setup lang="ts">
import { ref } from 'vue'

const props = defineProps<{
  variant: 'iso' | 'custom'
  busy: boolean
  progress: number | null
  error: string
  pinnedLabel: string
}>()

const emit = defineEmits<{
  pinFile: [file: File]
  pinUrl: [url: string]
}>()

const fileInput = ref<HTMLInputElement | null>(null)
const url = ref('')

function accept(): string {
  return props.variant === 'iso'
    ? '.iso'
    : '.iso,.img,.qcow2,.raw,.vmdk,.xz,.gz,.bz2,.zst'
}

function onPick(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (file) emit('pinFile', file)
}

function onDrop(event: DragEvent) {
  event.preventDefault()
  const file = event.dataTransfer?.files?.[0]
  if (file) emit('pinFile', file)
}

function submitUrl() {
  const trimmed = url.value.trim()
  if (trimmed) emit('pinUrl', trimmed)
}
</script>

<template>
  <div class="mag-pin">
    <label class="mag-pin-label">{{ variant === 'iso' ? 'Install ISO' : 'Image' }}</label>
    <div
      class="mag-drop"
      :class="{ busy: busy }"
      @click="!busy && fileInput?.click()"
      @dragover.prevent
      @drop="onDrop"
    >
      <input
        ref="fileInput"
        type="file"
        :accept="accept()"
        style="display:none"
        :disabled="busy"
        @change="onPick"
      />
      <b v-if="pinnedLabel && !busy">{{ pinnedLabel }}</b>
      <b v-else-if="variant === 'iso'">Drop your Windows installer here</b>
      <b v-else>Drop a disk image here</b>
      <template v-if="!pinnedLabel || busy">
        {{ variant === 'iso'
          ? 'An ISO file you downloaded from Microsoft.'
          : 'ISO or cloud image. Stays selected for this VM.' }}
      </template>
    </div>
    <div v-if="variant === 'custom'" class="mag-url">
      <input
        v-model="url"
        type="url"
        placeholder="https://example.com/image.iso"
        :disabled="busy"
        @keydown.enter.prevent="submitUrl"
      />
      <button type="button" class="mag-url-go" :disabled="busy || !url.trim()" @click="submitUrl">
        Use URL
      </button>
    </div>
    <div v-if="busy" class="mag-pin-bar">
      <span>{{ progress != null ? `${progress}%` : 'Working…' }}</span>
      <div class="mag-pin-track">
        <div
          class="mag-pin-fill"
          :class="{ indet: progress == null }"
          :style="progress != null ? { width: progress + '%' } : undefined"
        />
      </div>
    </div>
    <p v-if="error" class="mag-pin-err">{{ error }}</p>
  </div>
</template>

<style scoped>
.mag-pin { margin-top: 4px; }
.mag-pin-label {
  display: block;
  font-size: 10.5px;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--mag-dim);
  font-weight: 600;
  margin: 14px 0 7px;
}
.mag-drop {
  border: 1.5px dashed rgba(0, 144, 248, 0.45);
  border-radius: 2px;
  background: var(--accent-muted);
  padding: 20px;
  text-align: center;
  color: var(--mag-dim);
  font-size: 12.5px;
  cursor: pointer;
}
.mag-drop.busy { cursor: default; opacity: 0.8; }
.mag-drop b { color: var(--mag-text); display: block; font-size: 13px; margin-bottom: 4px; }
.mag-url {
  display: flex;
  gap: 8px;
  margin-top: 8px;
}
.mag-url input {
  flex: 1;
  width: 100%;
  font: inherit;
  font-size: 12.5px;
  color: var(--mag-text);
  background: var(--mag-input);
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  padding: 8px 10px;
}
.mag-url-go {
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  padding: 8px 12px;
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  background: none;
  color: var(--mag-text);
  cursor: pointer;
}
.mag-url-go:disabled { opacity: 0.5; cursor: not-allowed; }
.mag-pin-bar {
  margin-top: 8px;
  font-size: 11.5px;
  color: var(--mag-dim);
}
.mag-pin-track {
  margin-top: 6px;
  height: 6px;
  background: var(--mag-track);
  border-radius: 3px;
  overflow: hidden;
}
.mag-pin-fill {
  height: 100%;
  background: var(--mag-accent);
  transition: width 0.2s;
}
.mag-pin-fill.indet {
  width: 100%;
  animation: mag-pin-indet 1.5s ease-in-out infinite;
  background: linear-gradient(90deg, transparent 0%, var(--mag-accent) 50%, transparent 100%);
  background-size: 200% 100%;
}
@keyframes mag-pin-indet {
  0% { background-position: 200% 0; }
  100% { background-position: -200% 0; }
}
.mag-pin-err {
  margin: 8px 0 0;
  font-size: 12px;
  color: var(--red, #e5484d);
}
</style>
