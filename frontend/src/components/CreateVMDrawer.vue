<script setup lang="ts">
import { useCreateVMWizard } from '../composables/useCreateVMWizard'
import CreateVMOSStep from './create-vm/CreateVMOSStep.vue'
import CreateVMHardwareStep from './create-vm/CreateVMHardwareStep.vue'
import CreateVMImageStep from './create-vm/CreateVMImageStep.vue'
import CreateVMPlaceStep from './create-vm/CreateVMPlaceStep.vue'
import CreateVMDriversStep from './create-vm/CreateVMDriversStep.vue'
import CreateVMStorageStep from './create-vm/CreateVMStorageStep.vue'
import CreateVMNetworkStep from './create-vm/CreateVMNetworkStep.vue'
import CreateVMSummaryStep from './create-vm/CreateVMSummaryStep.vue'

const props = defineProps<{ initialHostId?: string }>()
const emit = defineEmits(['close', 'created'])

const {
  step,
  totalSteps,
  currentStepLabel,
  canProceed,
  next,
  prev,
  name,
  osType,
  workloadClass,
  isAgent,
  selectOS,
  cpuCount,
  hostCpuCount,
  memoryMB,
  displayResolution,
  tpmEnabled,
  uefi,
  effectiveGuestArch,
  archOptions,
  machineType,
  accelerator,
  cpuModel,
  alwaysShowArchDetails,
  setGuestArch,
  setAlwaysShowArchDetails,
  setTpmEnabled,
  mode,
  selectedImageId,
  selectedSSHKeyId,
  showCloudInit,
  cloudUserData,
  filteredImages,
  selectedImage,
  formatBytes,
  sshKeys,
  virtioWinAvailable,
  virtioWinDownloading,
  virtioWinProgress,
  virtioWinStatus,
  virtioWinError,
  startVirtioWinDownload,
  diskSource,
  diskSizeGB,
  existingDiskId,
  availableDisks,
  sharedPaths,
  showFolderPicker,
  hostUSBDevices,
  selectedUSBDevices,
  showUSBPicker,
  fetchUSBDevices,
  toggleUSBDevice,
  isUSBSelected,
  removeUSBDevice,
  networks,
  selectedNetworkId,
  selectedNetwork,
  portForwards,
  newPFProto,
  newPFHostPort,
  newPFGuestPort,
  addPortForward,
  removePortForward,
  isNAT,
  archLabel,
  revealArchOnSummary,
  archProblemText,
  error,
  loading,
  submit,
  selectedHostId,
  deviceOptions,
  selectedDevice,
  selectedDeviceIncompatibility,
  selectedDeviceBlocksPlacement,
  placementStepReached,
} = useCreateVMWizard((e) => emit(e), { initialHostId: props.initialHostId })

function openUSBPicker() {
  showUSBPicker.value = true
  fetchUSBDevices()
}
</script>

<template>
  <div class="modal-overlay" @click.self="emit('close')">
    <div class="modal" style="max-width:520px">
      <h2>Create Virtual Machine</h2>

      <!-- Step indicator -->
      <div class="wizard-steps">
        <div
          v-for="s in totalSteps"
          :key="s"
          class="wizard-dot"
          :class="{ active: s === step, done: s < step }"
          @click="s < step ? (step = s) : null"
        >
          {{ s }}
        </div>
      </div>

      <CreateVMOSStep
        v-if="currentStepLabel === 'Basics'"
        :name="name"
        :osType="osType"
        :workloadClass="workloadClass"
        @update:name="name = $event"
        @update:workloadClass="workloadClass = $event"
        @selectOS="selectOS"
        @next="next"
      />

      <CreateVMImageStep
        v-else-if="currentStepLabel === 'Image'"
        :osType="osType"
        :mode="mode"
        :selectedImageId="selectedImageId"
        :selectedSSHKeyId="selectedSSHKeyId"
        :showCloudInit="showCloudInit"
        :cloudUserData="cloudUserData"
        :filteredImages="filteredImages"
        :sshKeys="sshKeys"
        :formatBytes="formatBytes"
        @update:mode="mode = $event"
        @update:selectedImageId="selectedImageId = $event"
        @update:selectedSSHKeyId="selectedSSHKeyId = $event"
        @update:showCloudInit="showCloudInit = $event"
        @update:cloudUserData="cloudUserData = $event"
      />

      <CreateVMPlaceStep
        v-else-if="currentStepLabel === 'Place'"
        :selectedHostId="selectedHostId"
        :deviceOptions="deviceOptions"
        @update:selectedHostId="selectedHostId = $event"
      />

      <CreateVMHardwareStep
        v-else-if="currentStepLabel === 'Hardware'"
        :cpuCount="cpuCount"
        :memoryMB="memoryMB"
        :displayResolution="displayResolution"
        :guestArch="effectiveGuestArch"
        :archOptions="archOptions"
        :machineType="machineType"
        :accelerator="accelerator"
        :cpuModel="cpuModel"
        :uefi="uefi"
        :tpmEnabled="tpmEnabled"
        :alwaysShowArchDetails="alwaysShowArchDetails"
        :archProblem="archProblemText"
        :maxCpu="hostCpuCount"
        @update:cpuCount="cpuCount = $event"
        @update:memoryMB="memoryMB = $event"
        @update:displayResolution="displayResolution = $event"
        @update:guestArch="setGuestArch"
        @update:uefi="uefi = $event"
        @update:tpmEnabled="setTpmEnabled"
        @update:alwaysShowArchDetails="setAlwaysShowArchDetails"
      />

      <CreateVMDriversStep
        v-else-if="currentStepLabel === 'Drivers'"
        :virtioWinAvailable="virtioWinAvailable"
        :virtioWinDownloading="virtioWinDownloading"
        :virtioWinProgress="virtioWinProgress"
        :virtioWinStatus="virtioWinStatus"
        :virtioWinError="virtioWinError"
        @download="startVirtioWinDownload"
      />

      <CreateVMStorageStep
        v-else-if="currentStepLabel === 'Storage'"
        :diskSource="diskSource"
        :diskSizeGB="diskSizeGB"
        :existingDiskId="existingDiskId"
        :availableDisks="availableDisks"
        :sharedPaths="sharedPaths"
        :showFolderPicker="showFolderPicker"
        :formatBytes="formatBytes"
        :isAgent="isAgent"
        @update:diskSource="diskSource = $event"
        @update:diskSizeGB="diskSizeGB = $event"
        @update:existingDiskId="existingDiskId = $event"
        @update:sharedPaths="sharedPaths = $event"
        @update:showFolderPicker="showFolderPicker = $event"
      />

      <CreateVMNetworkStep
        v-else-if="currentStepLabel === 'Network'"
        :networks="networks"
        :selectedNetworkId="selectedNetworkId"
        :selectedNetwork="selectedNetwork"
        :isNAT="isNAT"
        :portForwards="portForwards"
        :newPFProto="newPFProto"
        :newPFHostPort="newPFHostPort"
        :newPFGuestPort="newPFGuestPort"
        :selectedUSBDevices="selectedUSBDevices"
        :showUSBPicker="showUSBPicker"
        :hostUSBDevices="hostUSBDevices"
        :isUSBSelected="isUSBSelected"
        :isAgent="isAgent"
        @update:selectedNetworkId="selectedNetworkId = $event"
        @update:newPFProto="newPFProto = $event"
        @update:newPFHostPort="newPFHostPort = $event"
        @update:newPFGuestPort="newPFGuestPort = $event"
        @update:showUSBPicker="showUSBPicker = $event"
        @addPortForward="addPortForward"
        @removePortForward="removePortForward"
        @removeUSBDevice="removeUSBDevice"
        @toggleUSBDevice="toggleUSBDevice"
        @openUSBPicker="openUSBPicker"
      />

      <CreateVMSummaryStep
        v-else-if="currentStepLabel === 'Summary'"
        :name="name"
        :osType="osType"
        :archLabel="archLabel"
        :cpuCount="cpuCount"
        :memoryMB="memoryMB"
        :displayResolution="displayResolution"
        :tpmEnabled="tpmEnabled"
        :uefi="uefi"
        :revealArchDetails="revealArchOnSummary"
        :archProblem="archProblemText"
        :mode="mode"
        :selectedImage="selectedImage"
        :diskSource="diskSource"
        :diskSizeGB="diskSizeGB"
        :existingDiskId="existingDiskId"
        :availableDisks="availableDisks"
        :sharedPaths="sharedPaths"
        :selectedUSBDevices="selectedUSBDevices"
        :selectedNetwork="selectedNetwork"
        :deviceLabel="selectedDevice ? (selectedDevice.displayName || selectedDevice.hostId) : ''"
        :placementWarning="selectedDeviceIncompatibility()"
        :placementBlocking="selectedDeviceBlocksPlacement()"
        :workloadClass="workloadClass"
      />

      <p
        v-if="placementStepReached && selectedDeviceIncompatibility() && currentStepLabel !== 'Summary'"
        class="placement-override"
      >
        {{ selectedDeviceIncompatibility() }}
        <template v-if="!selectedDeviceBlocksPlacement()"> You can still place the VM here.</template>
      </p>

      <!-- Error -->
      <p
        v-if="error"
        style="color:var(--red);font-size:13px;margin-top:12px;background:var(--red-muted);padding:8px 12px;border-radius:var(--radius-xs)"
      >
        {{ error }}
      </p>

      <!-- Navigation -->
      <div class="wizard-nav">
        <button class="btn-ghost" @click="step > 1 ? prev() : emit('close')">
          {{ step > 1 ? 'Back' : 'Cancel' }}
        </button>
        <div style="display:flex;gap:8px;align-items:center">
          <span style="font-size:12px;color:var(--text-dim)">Step {{ step }} of {{ totalSteps }}</span>
          <button
            v-if="step < totalSteps"
            class="btn-primary"
            :disabled="!canProceed()"
            @click="next"
          >
            Next
          </button>
          <button
            v-else
            class="btn-primary"
            :disabled="loading || !canProceed()"
            @click="submit"
          >
            {{ loading ? 'Creating...' : 'Create VM' }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.wizard-steps {
  display: flex;
  gap: 8px;
  justify-content: center;
  margin-bottom: 20px;
}
.wizard-dot {
  width: 28px;
  height: 28px;
  border-radius: 2px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  font-weight: 600;
  border: 2px solid var(--border);
  color: var(--text-dim);
  transition: all 0.2s;
}
.wizard-dot.active {
  border-color: var(--accent);
  color: var(--accent);
  background: rgba(99, 102, 241, 0.1);
}
.wizard-dot.done {
  border-color: var(--green);
  background: var(--green);
  color: #fff;
  cursor: pointer;
}
.wizard-nav {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-top: 20px;
  padding-top: 16px;
  border-top: 1px solid var(--border-subtle);
}
.placement-override {
  margin-top: 12px;
  padding: 8px 12px;
  border-radius: var(--radius-xs);
  background: rgba(217, 119, 6, 0.12);
  color: var(--amber, #d97706);
  font-size: 13px;
}
</style>
