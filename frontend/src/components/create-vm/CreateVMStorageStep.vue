<script setup lang="ts">
import AppSelect from '../ui/AppSelect.vue'
import FolderPicker from '../FolderPicker.vue'
import type { Disk } from '../../api/types'

defineProps<{
  diskSource: 'new' | 'existing'
  diskSizeGB: number
  existingDiskId: string
  availableDisks: Disk[]
  sharedPaths: string[]
  showFolderPicker: boolean
  formatBytes: (b: number) => string
}>()

const emit = defineEmits<{
  'update:diskSource': [value: 'new' | 'existing']
  'update:diskSizeGB': [value: number]
  'update:existingDiskId': [value: string]
  'update:sharedPaths': [value: string[]]
  'update:showFolderPicker': [value: boolean]
}>()

function addSharedPath(p: string, current: string[]) {
  if (!current.includes(p)) {
    emit('update:sharedPaths', [...current, p])
  }
}

function removeSharedPath(i: number, current: string[]) {
  const next = [...current]
  next.splice(i, 1)
  emit('update:sharedPaths', next)
}
</script>

<template>
  <div>
    <h3 class="step-title">Storage</h3>
    <div style="display:flex;gap:8px;margin-bottom:16px">
      <button
        :class="diskSource === 'new' ? 'btn-primary btn-sm' : 'btn-ghost btn-sm'"
        @click="emit('update:diskSource', 'new')"
      >
        New Disk
      </button>
      <button
        :class="diskSource === 'existing' ? 'btn-primary btn-sm' : 'btn-ghost btn-sm'"
        @click="emit('update:diskSource', 'existing')"
      >
        Existing Disk
      </button>
    </div>

    <div v-if="diskSource === 'new'" class="form-group">
      <label>Disk Size (GB)</label>
      <input
        :value="diskSizeGB"
        type="number"
        min="1"
        @input="emit('update:diskSizeGB', Number(($event.target as HTMLInputElement).value))"
      />
      <span style="font-size:11px;color:var(--text-dim);margin-top:4px;display:block">
        A QCOW2 virtual disk will be created. It grows dynamically — only used space is allocated on this device.
      </span>
    </div>

    <div v-if="diskSource === 'existing'" class="form-group">
      <label>Select Disk</label>
      <AppSelect
        :modelValue="existingDiskId"
        @update:modelValue="emit('update:existingDiskId', $event as string)"
      >
        <option value="" disabled>Select a disk...</option>
        <option v-for="d in availableDisks" :key="d.id" :value="d.id">
          {{ d.name }} ({{ formatBytes(d.sizeBytes) }}, {{ d.format }})
        </option>
      </AppSelect>
      <div v-if="availableDisks.length === 0" style="margin-top:6px;font-size:12px;color:var(--text-dim)">
        No unattached disks available. Create one on the Disks page first.
      </div>
    </div>

    <div style="margin-top:16px">
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:8px">
        <label style="margin:0">Shared Folders (optional)</label>
        <button class="btn-ghost btn-sm" @click="emit('update:showFolderPicker', true)">
          <span style="display:flex;align-items:center;gap:4px">
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/></svg>
            Add
          </span>
        </button>
      </div>
      <div v-if="sharedPaths.length > 0" style="border:1px solid var(--border);border-radius:var(--radius-sm);overflow:hidden;margin-bottom:8px">
        <div
          v-for="(p, i) in sharedPaths"
          :key="p"
          style="display:flex;align-items:center;justify-content:space-between;padding:6px 10px;font-size:12px;font-family:var(--font-mono);border-bottom:1px solid var(--border-subtle)"
        >
          <span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{{ p }}</span>
          <button
            class="btn-ghost btn-sm"
            style="color:var(--red);flex-shrink:0;margin-left:8px"
            @click="removeSharedPath(i, sharedPaths)"
          >
            Remove
          </button>
        </div>
      </div>
      <span style="font-size:11px;color:var(--text-dim);display:block">
        Host directories shared via virtio-9p. Mount inside guest: <code style="background:var(--bg);padding:1px 4px;border-radius:1px;font-size:10px">mount -t 9p -o trans=virtio hostshare /mnt/share</code>
      </span>
    </div>

    <FolderPicker
      v-if="showFolderPicker"
      :modelValue="''"
      @update:modelValue="(p: string) => addSharedPath(p, sharedPaths)"
      @close="emit('update:showFolderPicker', false)"
    />
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
