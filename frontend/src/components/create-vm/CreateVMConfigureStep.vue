<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import AppSelect from '../ui/AppSelect.vue'
import type { DevicePickOption } from '../../utils/deviceCompatibility'
import type { Image } from '../../api/types'
import type { SizePreset } from '../../utils/hostBuffer'
import { hostnameFromVMName } from '../../utils/hostnameFromVMName'

const props = defineProps<{
  name: string
  showHostnameHint: boolean
  selectedHostId: string
  deviceOptions: DevicePickOption[]
  sizePresets: SizePreset[]
  selectedPresetId: string
  dedicated: boolean
  leftoverText: string
  sharedLeftoverText: string
  atResourceCap: boolean
  capHintText: string
  showIsoDrop: boolean
  showCustomImage: boolean
  mode: 'iso' | 'cloud'
  selectedImageId: string
  filteredImages: Image[]
  cpuCount: number
  memoryMB: number
  cpuCap: number
  memCapGB: number
  networkBridged: boolean
  uefi: boolean
  tpmEnabled: boolean
  tpmWhy: string
  showSshKey: boolean
  selectedSSHKeyId: string
  sshKeyOptions: Array<{ value: string; label: string }>
}>()

const emit = defineEmits<{
  'update:name': [value: string]
  'update:selectedHostId': [value: string]
  'update:selectedPresetId': [value: string]
  'update:dedicated': [value: boolean]
  'update:mode': [value: 'iso' | 'cloud']
  'update:selectedImageId': [value: string]
  'update:cpuCount': [value: number]
  'update:memoryMB': [value: number]
  'update:networkBridged': [value: boolean]
  'update:uefi': [value: boolean]
  'update:tpmEnabled': [value: boolean]
  'update:selectedSSHKeyId': [value: string]
  isoSelected: [file: File]
}>()

const advancedOpen = ref(false)
const fileInput = ref<HTMLInputElement | null>(null)

const hostnameSlug = computed(() => hostnameFromVMName(props.name))
const memCount = computed(() => Math.max(1, Math.round(props.memoryMB / 1024)))

function clampCpu(raw: number) {
  return Math.min(props.cpuCap, Math.max(1, Math.round(raw) || 1))
}

function clampMemGB(raw: number) {
  return Math.min(props.memCapGB, Math.max(1, Math.round(raw) || 1))
}

function onCpuNumber(raw: string) {
  emit('update:cpuCount', clampCpu(Number(raw)))
}

function onMemNumber(raw: string) {
  const gb = clampMemGB(Number(raw))
  emit('update:memoryMB', gb * 1024)
}

function onCpuRange(raw: string) {
  emit('update:cpuCount', clampCpu(Number(raw)))
}

function onMemRange(raw: string) {
  const gb = clampMemGB(Number(raw))
  emit('update:memoryMB', gb * 1024)
}

function paintRange(el: HTMLInputElement | null) {
  if (!el) return
  const min = Number(el.min)
  const max = Number(el.max)
  const val = Number(el.value)
  const p = max > min ? ((val - min) / (max - min)) * 100 : 0
  el.style.background = `linear-gradient(90deg, var(--mag-accent) ${p}%, var(--mag-track) ${p}%)`
}

watch([() => props.cpuCount, () => props.memoryMB, advancedOpen], () => {
  requestAnimationFrame(() => {
    paintRange(document.getElementById('mag-cpu-range') as HTMLInputElement | null)
    paintRange(document.getElementById('mag-mem-range') as HTMLInputElement | null)
  })
}, { immediate: true })

function deviceLine(option: DevicePickOption): string {
  const parts: string[] = []
  if (option.platformLine) parts.push(option.platformLine)
  return parts.join(' · ')
}

function onIsoPick(event: Event) {
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  if (file) emit('isoSelected', file)
}
</script>

<template>
  <div>
    <label class="mag-flabel">Name</label>
    <input
      :value="name"
      @input="emit('update:name', ($event.target as HTMLInputElement).value)"
    />
    <p v-if="showHostnameHint" class="mag-hostname">
      Also the hostname: {{ hostnameSlug }}
    </p>

    <label class="mag-flabel">Device</label>
    <button
      v-for="option in deviceOptions"
      :key="option.hostId"
      type="button"
      class="mag-dev"
      :class="{ on: selectedHostId === option.hostId, off: !option.reachable }"
      :disabled="!option.reachable"
      @click="option.reachable && emit('update:selectedHostId', option.hostId)"
    >
      <span class="mag-dot" :class="option.reachable ? 'ok' : 'off'" />
      <b>{{ option.label }}</b>
      <span>{{ deviceLine(option) }}</span>
    </button>

    <div v-if="showCustomImage" class="mag-image-pick">
      <label class="mag-flabel">Image</label>
      <div class="mag-mode">
        <button type="button" :class="{ on: mode === 'iso' }" @click="emit('update:mode', 'iso')">ISO</button>
        <button type="button" :class="{ on: mode === 'cloud' }" @click="emit('update:mode', 'cloud')">Cloud image</button>
      </div>
      <AppSelect
        :model-value="selectedImageId"
        placeholder="Select an image"
        :options="filteredImages.map((img) => ({ value: img.libraryKey || img.id, label: img.name }))"
        @update:model-value="emit('update:selectedImageId', $event as string)"
      />
    </div>

    <label class="mag-flabel">Size</label>
    <div class="mag-sizes">
      <button
        v-for="preset in sizePresets"
        :key="preset.id"
        type="button"
        class="mag-size"
        :class="{ on: selectedPresetId === preset.id }"
        @click="emit('update:selectedPresetId', preset.id)"
      >
        <b>{{ preset.label }}</b>
        <span>{{ preset.cpu }} CPU · {{ preset.memGB }} GB · {{ preset.diskGB }} GB</span>
      </button>
    </div>

    <div class="mag-dedi">
      <div>
        <b>Dedicated to this VM</b>
        <span>These cores and this memory are reserved for the VM. The Device will not use them for itself.</span>
      </div>
      <button
        type="button"
        class="mag-tgl"
        :class="{ on: dedicated }"
        aria-label="Dedicated to this VM"
        @click="emit('update:dedicated', !dedicated)"
      />
    </div>
    <p class="mag-leftover" v-html="dedicated ? leftoverText : sharedLeftoverText" />

    <div v-if="showIsoDrop" class="mag-drop" @click="fileInput?.click()">
      <input ref="fileInput" type="file" accept=".iso" style="display:none" @change="onIsoPick" />
      <b>Drop your Windows installer here</b>
      An ISO file you downloaded from Microsoft. We take it from there.
    </div>

    <details class="mag-adv">
      <summary>Advanced</summary>
      <div class="mag-advbody">
        <div class="mag-advgrid">
          <div>
            <label>CPU cores</label>
            <div class="mag-hw">
              <input type="number" :value="cpuCount" :min="1" :max="cpuCap" @change="onCpuNumber(($event.target as HTMLInputElement).value)" />
              <input id="mag-cpu-range" type="range" :min="1" :max="cpuCap" step="1" :value="cpuCount" @input="onCpuRange(($event.target as HTMLInputElement).value)" />
              <span class="mag-cap">of {{ cpuCap }}</span>
            </div>
          </div>
          <div>
            <label>Memory GB</label>
            <div class="mag-hw">
              <input type="number" :value="memCount" :min="1" :max="memCapGB" @change="onMemNumber(($event.target as HTMLInputElement).value)" />
              <input id="mag-mem-range" type="range" :min="1" :max="memCapGB" step="1" :value="memCount" @input="onMemRange(($event.target as HTMLInputElement).value)" />
              <span class="mag-cap">of {{ memCapGB }}</span>
            </div>
          </div>
          <div>
            <label>Network</label>
            <AppSelect
              :model-value="networkBridged ? 'bridged' : 'nat'"
              :options="[
                { value: 'nat', label: 'Shared (NAT)' },
                { value: 'bridged', label: 'Bridged' },
              ]"
              @update:model-value="emit('update:networkBridged', $event === 'bridged')"
            />
          </div>
        </div>
        <p class="mag-hint" :class="{ on: atResourceCap }">{{ capHintText }}</p>
        <div class="mag-fwrow">
          <div>
            <b>UEFI firmware</b>
            <span>Needed for Windows and most modern Linux.</span>
          </div>
          <button type="button" class="mag-tgl" :class="{ on: uefi }" aria-label="UEFI firmware" @click="emit('update:uefi', !uefi)" />
        </div>
        <div class="mag-fwrow">
          <div>
            <b>TPM 2.0</b>
            <span>{{ tpmWhy }}</span>
          </div>
          <button type="button" class="mag-tgl" :class="{ on: tpmEnabled }" aria-label="TPM 2.0" @click="emit('update:tpmEnabled', !tpmEnabled)" />
        </div>
        <div v-if="showSshKey" class="mag-fwrow">
          <div>
            <b>SSH key</b>
            <span>Used for first login to this VM.</span>
          </div>
          <AppSelect
            :model-value="selectedSSHKeyId"
            :options="sshKeyOptions"
            @update:model-value="emit('update:selectedSSHKeyId', $event as string)"
          />
        </div>
      </div>
    </details>
  </div>
</template>

<style scoped>
.mag-flabel {
  display: block;
  font-size: 10.5px;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--mag-dim);
  font-weight: 600;
  margin: 14px 0 7px;
}
.mag-flabel:first-child { margin-top: 0; }
input, select {
  width: 100%;
  font: inherit;
  font-size: 12.5px;
  color: var(--mag-text);
  background: var(--mag-input);
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  padding: 8px 10px;
}
.mag-hostname {
  margin-top: 6px;
  font-size: 11.5px;
  color: var(--mag-dim);
}
.mag-dev {
  width: 100%;
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 9px 11px;
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  margin-bottom: 8px;
  cursor: pointer;
  background: none;
  color: inherit;
  text-align: left;
}
.mag-dev b { font-size: 12.5px; }
.mag-dev span { margin-left: auto; font-size: 11px; color: var(--mag-dim); }
.mag-dev.on { border-color: var(--mag-accent); background: var(--accent-muted); }
.mag-dev.off { opacity: 0.5; cursor: not-allowed; }
.mag-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
.mag-dot.ok { background: var(--green); }
.mag-dot.off { background: var(--mag-dim); }
.mag-sizes { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
.mag-size {
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  background: var(--mag-panel);
  padding: 14px;
  cursor: pointer;
  text-align: center;
  color: inherit;
}
.mag-size b { display: block; font-size: 13.5px; margin-bottom: 4px; }
.mag-size span { font-size: 11px; color: var(--mag-dim); }
.mag-size.on { border-color: var(--mag-accent); background: var(--accent-muted); }
.mag-dedi {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-top: 14px;
  padding: 11px 12px;
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  background: var(--mag-panel);
}
.mag-dedi b { font-size: 12.5px; display: block; }
.mag-dedi span { font-size: 11px; color: var(--mag-dim); display: block; margin-top: 2px; line-height: 1.45; }
.mag-tgl {
  position: relative;
  width: 34px;
  height: 19px;
  border-radius: 10px;
  background: var(--mag-track);
  border: 1px solid var(--mag-line);
  cursor: pointer;
  flex-shrink: 0;
  padding: 0;
  margin-left: auto;
}
.mag-tgl::after {
  content: '';
  position: absolute;
  left: 2px;
  top: 2px;
  width: 13px;
  height: 13px;
  border-radius: 50%;
  background: var(--mag-dim);
  transition: left 0.15s;
}
.mag-tgl.on { background: rgba(0, 144, 248, 0.35); border-color: rgba(0, 144, 248, 0.55); }
.mag-tgl.on::after { left: 17px; background: var(--accent-text); }
.mag-leftover { margin-top: 8px; font-size: 11.5px; color: var(--mag-dim); }
.mag-drop {
  margin-top: 14px;
  border: 1.5px dashed rgba(0, 144, 248, 0.45);
  border-radius: 2px;
  background: var(--accent-muted);
  padding: 20px;
  text-align: center;
  color: var(--mag-dim);
  font-size: 12.5px;
  cursor: pointer;
}
.mag-drop b { color: var(--mag-text); display: block; font-size: 13px; margin-bottom: 4px; }
.mag-adv {
  margin-top: 16px;
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  background: var(--mag-panel);
}
.mag-adv summary {
  cursor: pointer;
  padding: 10px 12px;
  font-size: 12px;
  font-weight: 600;
  color: var(--mag-dim);
  list-style: none;
}
.mag-adv summary::before { content: '+'; margin-right: 8px; color: var(--mag-accent); }
.mag-adv[open] summary::before { content: '-'; }
.mag-advbody { padding: 2px 12px 12px; }
.mag-advgrid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 12px 14px;
  padding-top: 12px;
}
.mag-advgrid label {
  font-size: 10.5px;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--mag-dim);
  font-weight: 600;
  display: block;
  margin-bottom: 5px;
}
.mag-hw { display: flex; align-items: center; gap: 10px; }
.mag-hw input[type=number] { width: 74px; flex-shrink: 0; }
.mag-hw input[type=range] {
  flex: 1;
  appearance: none;
  height: 5px;
  border-radius: 3px;
  background: var(--mag-track);
  padding: 0;
  border: 0;
  cursor: pointer;
}
.mag-hw input[type=range]::-webkit-slider-thumb {
  appearance: none;
  width: 16px;
  height: 16px;
  border-radius: 50%;
  background: var(--modal-surface);
  border: 3px solid var(--mag-accent);
  cursor: pointer;
}
.mag-cap { font-size: 10.5px; color: var(--mag-dim); flex-shrink: 0; font-variant-numeric: tabular-nums; }
.mag-hint { display: none; margin-top: 10px; font-size: 11.5px; font-weight: 600; color: var(--amber); }
.mag-hint.on { display: block; }
.mag-fwrow {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 0;
  border-top: 1px solid var(--mag-line);
}
.mag-fwrow:first-of-type { margin-top: 12px; }
.mag-fwrow b { font-size: 12.5px; display: block; }
.mag-fwrow span { font-size: 11px; color: var(--mag-dim); display: block; margin-top: 2px; }
.mag-fwrow :deep(select) { width: 220px; margin-left: auto; }
.mag-image-pick { margin-top: 4px; }
.mag-mode { display: flex; gap: 8px; margin-bottom: 8px; }
.mag-mode button {
  font: inherit;
  font-size: 12px;
  padding: 6px 10px;
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  background: none;
  color: var(--mag-dim);
  cursor: pointer;
}
.mag-mode button.on {
  color: var(--mag-text);
  border-color: rgba(0, 144, 248, 0.55);
  background: var(--accent-muted);
}
</style>
