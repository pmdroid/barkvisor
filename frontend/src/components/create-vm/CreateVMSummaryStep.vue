<script setup lang="ts">
import type { Disk, Network, USBPassthroughDevice, Image } from '../../api/types'
import { useFeature } from '../../composables/useFeature'

const usb = useFeature('usbPassthrough')

defineProps<{
  name: string
  osType: 'linux' | 'windows'
  archLabel: string
  cpuCount: number
  memoryMB: number
  displayResolution: string
  tpmEnabled: boolean
  uefi: boolean
  revealArchDetails: boolean
  archProblem: string | null
  mode: 'iso' | 'cloud'
  selectedImage: Image | null | undefined
  diskSource: 'new' | 'existing'
  diskSizeGB: number
  existingDiskId: string
  availableDisks: Disk[]
  sharedPaths: string[]
  selectedUSBDevices: USBPassthroughDevice[]
  selectedNetwork: Network | null
  deviceLabel?: string
}>()
</script>

<template>
  <div>
    <h3 class="step-title">Summary</h3>
    <div class="summary-grid">
      <div v-if="deviceLabel" class="summary-row">
        <span class="summary-label">Device</span>
        <span>{{ deviceLabel }}</span>
      </div>
      <div class="summary-row">
        <span class="summary-label">Name</span>
        <span>{{ name }}</span>
      </div>
      <div class="summary-row">
        <span class="summary-label">OS</span>
        <span>{{ osType === 'linux' ? 'Linux' : 'Windows' }}</span>
      </div>
      <div v-if="revealArchDetails" class="summary-row">
        <span class="summary-label">Architecture</span>
        <span>
          {{ archLabel }}
          <span v-if="archProblem" class="arch-warn">{{ archProblem }}</span>
        </span>
      </div>
      <div class="summary-row">
        <span class="summary-label">CPU</span>
        <span>{{ cpuCount }} cores</span>
      </div>
      <div class="summary-row">
        <span class="summary-label">Memory</span>
        <span>{{ memoryMB }} MB</span>
      </div>
      <div class="summary-row">
        <span class="summary-label">Display</span>
        <span>{{ displayResolution }}</span>
      </div>
      <div v-if="revealArchDetails" class="summary-row">
        <span class="summary-label">Firmware</span>
        <span>{{ uefi ? 'UEFI' : 'Off' }}</span>
      </div>
      <div v-if="revealArchDetails" class="summary-row">
        <span class="summary-label">TPM</span>
        <span>{{ tpmEnabled ? 'TPM 2.0' : 'Off' }}</span>
      </div>
      <div class="summary-row">
        <span class="summary-label">Image</span>
        <span>
          <span class="badge badge-gray" style="margin-right:4px">{{ mode }}</span>
          {{ selectedImage?.name || '—' }}
        </span>
      </div>
      <div class="summary-row">
        <span class="summary-label">Disk</span>
        <span v-if="diskSource === 'existing'">{{ availableDisks.find(d => d.id === existingDiskId)?.name || 'Selected disk' }}</span>
        <span v-else>{{ diskSizeGB }} GB (qcow2, new)</span>
      </div>
      <div v-if="sharedPaths.length" class="summary-row">
        <span class="summary-label">Shared</span>
        <span style="font-family:var(--font-mono);font-size:12px">{{ sharedPaths.join(', ') }}</span>
      </div>
      <div v-if="usb.available && selectedUSBDevices.length" class="summary-row">
        <span class="summary-label">USB</span>
        <span style="font-size:12px">{{ selectedUSBDevices.map(d => d.label || `${d.vendorId}:${d.productId}`).join(', ') }}</span>
      </div>
      <div class="summary-row">
        <span class="summary-label">Network</span>
        <span>{{ selectedNetwork ? `${selectedNetwork.name} (${selectedNetwork.mode})` : 'Default NAT' }}</span>
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
.summary-grid {
  display: flex;
  flex-direction: column;
}
.summary-row {
  display: flex;
  padding: 10px 0;
  border-bottom: 1px solid var(--border-subtle);
  font-size: 13px;
}
.summary-row:last-child { border-bottom: none; }
.summary-label {
  width: 120px;
  flex-shrink: 0;
  font-weight: 600;
  color: var(--text-dim);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.03em;
}
.arch-warn {
  display: block;
  margin-top: 4px;
  font-size: 12px;
  color: var(--amber);
  text-transform: none;
  letter-spacing: 0;
  font-weight: 500;
}
</style>
