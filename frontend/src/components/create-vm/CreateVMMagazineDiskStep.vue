<script setup lang="ts">
import type { Disk, HostBlockDevice } from '../../api/types'

const props = defineProps<{
  diskSource: 'new' | 'existing' | 'raw'
  diskSizeGB: number
  existingDiskId: string
  availableDisks: Disk[]
  selectedPresetLabel: string
  rawAvailable: boolean
  rawWhy: string
  blockDevices: HostBlockDevice[]
  blockDevicePath: string
  formatBytes: (b: number) => string
}>()

const emit = defineEmits<{
  'update:diskSource': [value: 'new' | 'existing' | 'raw']
  'update:diskSizeGB': [value: number]
  'update:existingDiskId': [value: string]
  'update:blockDevicePath': [value: string]
}>()

function pickExisting(id: string, event: Event) {
  event.stopPropagation()
  emit('update:existingDiskId', id)
}

function pickRaw(path: string, attachable: boolean, event: Event) {
  event.stopPropagation()
  if (!attachable) return
  emit('update:blockDevicePath', path)
}
</script>

<template>
  <div class="mag-dcards">
    <div
      class="mag-dcard"
      :class="{ on: diskSource === 'new' }"
      @click="emit('update:diskSource', 'new')"
    >
      <div class="mag-dtt">
        <b>New disk</b>
        <span class="mag-dfm">QCOW2, grows as used</span>
      </div>
      <p>A virtual disk on this Device.</p>
      <div class="mag-dsize">
        <label>Size GB</label>
        <input
          type="number"
          :value="diskSizeGB"
          min="1"
          @click.stop
          @change="emit('update:diskSizeGB', Math.max(1, Math.round(Number(($event.target as HTMLInputElement).value)) || 1))"
        />
        <span>From the {{ selectedPresetLabel }} preset</span>
      </div>
    </div>

    <div
      class="mag-dcard"
      :class="{ on: diskSource === 'existing' }"
      @click="emit('update:diskSource', 'existing')"
    >
      <div class="mag-dtt">
        <b>Existing disk</b>
        <span class="mag-dfm">Attach as is</span>
      </div>
      <p>An unused disk already on this Device.</p>
      <div v-if="availableDisks.length" class="mag-dlist">
        <button
          v-for="disk in availableDisks"
          :key="disk.id"
          type="button"
          class="mag-dopt"
          :class="{ on: existingDiskId === disk.id }"
          @click="pickExisting(disk.id, $event)"
        >
          {{ disk.name }}
          <span>{{ formatBytes(disk.sizeBytes) }}, unused</span>
        </button>
      </div>
      <p v-else class="mag-empty">No unused disks on this Device.</p>
    </div>

    <div
      class="mag-dcard"
      :class="{ on: diskSource === 'raw', off: !rawAvailable }"
      @click="rawAvailable && emit('update:diskSource', 'raw')"
    >
      <div class="mag-dtt">
        <b>Raw host device</b>
        <span class="mag-dfm">Linux Devices only</span>
      </div>
      <p>{{ rawWhy }}</p>
      <div v-if="rawAvailable && blockDevices.length" class="mag-dlist">
        <button
          v-for="dev in blockDevices"
          :key="dev.path"
          type="button"
          class="mag-dopt"
          :class="{ on: blockDevicePath === dev.path, off: !dev.attachable }"
          @click="pickRaw(dev.path, dev.attachable, $event)"
        >
          <code>{{ dev.path }}</code>
          <span>{{ formatBytes(dev.sizeBytes) }}{{ dev.attachable ? ', unused' : `, ${dev.excludedReason || 'in use'}` }}</span>
        </button>
      </div>
    </div>
  </div>

  <div v-if="diskSource === 'raw' && rawAvailable" class="mag-confirm">
    <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.4">
      <path d="M7 1.5L13 12H1z" stroke-linejoin="round" />
      <path d="M7 5.5v3" stroke-linecap="round" />
      <circle cx="7" cy="10.2" r=".7" fill="currentColor" stroke="none" />
    </svg>
    <span>BarkVisor will not format or wipe this device. The host must not be using it.</span>
  </div>
</template>

<style scoped>
.mag-dcards { display: flex; flex-direction: column; gap: 12px; }
.mag-dcard {
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  background: var(--mag-panel);
  padding: 16px;
  cursor: pointer;
}
.mag-dcard:hover { border-color: rgba(0, 144, 248, 0.5); }
.mag-dcard.on { border-color: var(--mag-accent); background: var(--accent-muted); }
.mag-dcard.off { opacity: 0.5; cursor: not-allowed; }
.mag-dcard.off:hover { border-color: var(--mag-line); }
.mag-dtt { display: flex; align-items: baseline; gap: 10px; }
.mag-dtt b { font-size: 14px; }
.mag-dfm { margin-left: auto; font-size: 11px; color: var(--mag-dim); font-weight: 600; }
.mag-dcard > p { font-size: 12px; color: var(--mag-dim); margin-top: 5px; line-height: 1.5; }
.mag-dsize { display: flex; align-items: center; gap: 10px; margin-top: 12px; }
.mag-dsize label {
  font-size: 10.5px;
  text-transform: uppercase;
  letter-spacing: 0.07em;
  color: var(--mag-dim);
  font-weight: 600;
  flex-shrink: 0;
}
.mag-dsize input {
  width: 90px;
  font: inherit;
  font-size: 12.5px;
  color: var(--mag-text);
  background: var(--mag-input);
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  padding: 8px 10px;
}
.mag-dsize span { font-size: 11px; color: var(--mag-dim); }
.mag-dlist { margin-top: 12px; display: flex; flex-direction: column; gap: 7px; }
.mag-dopt {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 11px;
  border: 1px solid var(--mag-line);
  border-radius: 2px;
  font-size: 12.5px;
  font-weight: 600;
  cursor: pointer;
  background: none;
  color: inherit;
  width: 100%;
  text-align: left;
}
.mag-dopt span { margin-left: auto; font-size: 11px; color: var(--mag-dim); font-weight: 500; }
.mag-dopt.on { border-color: var(--mag-accent); background: var(--accent-muted); }
.mag-dopt.off { opacity: 0.5; cursor: not-allowed; }
.mag-dopt code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
.mag-empty { margin-top: 8px; font-size: 12px; color: var(--mag-dim); }
.mag-confirm {
  margin-top: 12px;
  display: flex;
  gap: 9px;
  align-items: flex-start;
  border: 1px solid rgba(251, 191, 36, 0.4);
  background: rgba(251, 191, 36, 0.07);
  border-radius: 2px;
  padding: 10px 12px;
  font-size: 12px;
  line-height: 1.5;
  color: var(--mag-text);
}
.mag-confirm svg { flex-shrink: 0; color: #fbbf24; margin-top: 1px; }
</style>
