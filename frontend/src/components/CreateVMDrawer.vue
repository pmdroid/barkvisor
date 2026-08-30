<script setup lang="ts">
import { computed } from 'vue'
import { useCreateVMWizard } from '../composables/useCreateVMWizard'
import CreateVMGalleryStep from './create-vm/CreateVMGalleryStep.vue'
import CreateVMConfigureStep from './create-vm/CreateVMConfigureStep.vue'
import CreateVMMagazineDiskStep from './create-vm/CreateVMMagazineDiskStep.vue'

const props = defineProps<{ initialHostId?: string }>()
const emit = defineEmits(['close', 'created'])

const wizard = useCreateVMWizard((e) => emit(e), { initialHostId: props.initialHostId })

const stepLabel = computed(() => `Step ${wizard.step.value} of ${wizard.totalSteps.value}`)
const showImagePin = computed(() =>
  wizard.galleryKind.value === 'windows' || wizard.galleryKind.value === 'custom',
)
const imagePinVariant = computed(() => wizard.galleryKind.value === 'windows' ? 'iso' : 'custom')
</script>

<template>
  <div class="mag-overlay" @click.self="emit('close')">
    <div class="mag-frame">
      <div class="mag-head">
        <h2>{{ wizard.headTitle.value }}</h2>
        <span class="mag-step">{{ stepLabel }}</span>
      </div>
      <div class="mag-body">
        <CreateVMGalleryStep
          v-if="wizard.currentStepLabel.value === 'Gallery'"
          :templates="wizard.galleryTemplates.value"
          :show-coding-agent="wizard.showCodingAgentCard.value"
          :selected-kind="wizard.galleryKind.value"
          :selected-template-slug="wizard.selectedTemplateSlug.value"
          @select-template="wizard.selectGalleryTemplate"
          @select-windows="wizard.selectGalleryWindows"
          @select-custom="wizard.selectGalleryCustom"
          @select-coding-agent="wizard.selectGalleryCodingAgent"
        />

        <CreateVMConfigureStep
          v-else-if="wizard.currentStepLabel.value === 'Configure'"
          :name="wizard.name.value"
          :show-hostname-hint="wizard.showHostnameHint.value"
          :selected-host-id="wizard.selectedHostId.value"
          :device-options="wizard.deviceOptions.value"
          :size-presets="wizard.sizePresets.value"
          :selected-preset-id="wizard.selectedPresetId.value"
          :dedicated="wizard.dedicated.value"
          :leftover-text="wizard.leftoverText.value"
          :shared-leftover-text="wizard.sharedLeftoverText.value"
          :at-resource-cap="wizard.atResourceCap.value"
          :cap-hint-text="wizard.capHintText.value"
          :show-image-pin="showImagePin"
          :image-pin-variant="imagePinVariant"
          :pin-busy="wizard.imagePinBusy.value"
          :pin-progress="wizard.imagePinProgress.value"
          :pin-error="wizard.imagePinError.value"
          :pinned-label="wizard.pinnedImageLabel.value"
          :cpu-count="wizard.cpuCount.value"
          :memory-m-b="wizard.memoryMB.value"
          :cpu-cap="wizard.vmCpuCapValue.value"
          :mem-cap-g-b="wizard.vmMemCapGB.value"
          :network-bridged="wizard.networkBridged.value"
          :cloud-init-capable="wizard.mode.value === 'cloud'"
          :guest-address-mode="wizard.guestAddressMode.value"
          :guest-i-pv4="wizard.guestIPv4.value"
          :guest-prefix-length="wizard.guestPrefixLength.value"
          :guest-gateway="wizard.guestGateway.value"
          :guest-nameservers="wizard.guestNameservers.value"
          :uefi="wizard.uefi.value"
          :tpm-enabled="wizard.tpmEnabled.value"
          :tpm-why="wizard.tpmWhyText.value"
          :show-ssh-key="wizard.showSshKeyRow.value"
          :selected-s-s-h-key-id="wizard.selectedSSHKeyId.value"
          :ssh-key-options="wizard.sshKeyOptions.value"
          :template-inputs="wizard.templateInputs.value"
          :template-input-values="wizard.templateInputValues.value"
          @update:name="wizard.name.value = $event"
          @update:selected-host-id="wizard.selectedHostId.value = $event"
          @update:selected-preset-id="wizard.applySizeFromPresetId($event)"
          @update:dedicated="wizard.dedicated.value = $event"
          @update:cpu-count="wizard.cpuCount.value = $event"
          @update:memory-m-b="wizard.memoryMB.value = $event"
          @update:network-bridged="wizard.networkBridged.value = $event"
          @update:guest-address-mode="wizard.guestAddressMode.value = $event"
          @update:guest-i-pv4="wizard.guestIPv4.value = $event"
          @update:guest-prefix-length="wizard.guestPrefixLength.value = $event"
          @update:guest-gateway="wizard.guestGateway.value = $event"
          @update:guest-nameservers="wizard.guestNameservers.value = $event"
          @update:uefi="wizard.uefi.value = $event"
          @update:tpm-enabled="wizard.setTpmEnabled($event)"
          @update:selected-s-s-h-key-id="wizard.selectedSSHKeyId.value = $event"
          @set-template-input="wizard.setTemplateInput"
          @pin-file="wizard.pinLocalFile"
          @pin-url="wizard.pinRemoteUrl"
        />

        <CreateVMMagazineDiskStep
          v-else-if="wizard.currentStepLabel.value === 'Disk'"
          :disk-source="wizard.diskSource.value"
          :disk-size-g-b="wizard.diskSizeGB.value"
          :existing-disk-id="wizard.existingDiskId.value"
          :available-disks="wizard.availableDisks.value"
          :selected-preset-label="wizard.selectedPreset.value?.label || 'Medium'"
          :raw-available="wizard.rawDiskAvailable.value"
          :raw-why="wizard.rawDiskWhy.value"
          :block-devices="wizard.blockDevices.value"
          :block-device-path="wizard.blockDevicePath.value"
          :format-bytes="wizard.formatBytes"
          :shared-paths="wizard.sharedPaths.value"
          :show-shared-folders="!wizard.isAgent.value"
          :device="wizard.selectedDevice.value"
          @update:disk-source="wizard.diskSource.value = $event"
          @update:disk-size-g-b="wizard.diskSizeGB.value = $event"
          @update:existing-disk-id="wizard.existingDiskId.value = $event"
          @update:block-device-path="wizard.blockDevicePath.value = $event"
          @update:shared-paths="wizard.sharedPaths.value = $event"
        />

        <p v-if="wizard.error.value" class="mag-error">{{ wizard.error.value }}</p>
      </div>
      <div class="mag-foot">
        <button type="button" class="mag-btn ghost" @click="wizard.step.value > 1 ? wizard.prev() : emit('close')">
          {{ wizard.step.value > 1 ? 'Back' : 'Cancel' }}
        </button>
        <button
          v-if="wizard.step.value < wizard.totalSteps.value && wizard.step.value > 1"
          type="button"
          class="mag-btn primary"
          :disabled="!wizard.canProceed()"
          @click="wizard.step.value === 2 ? wizard.goToDisk() : wizard.next()"
        >
          Next
        </button>
        <button
          v-else-if="wizard.step.value === wizard.totalSteps.value"
          type="button"
          class="mag-btn primary"
          :disabled="wizard.loading.value || !wizard.canProceed()"
          @click="wizard.submit"
        >
          {{ wizard.loading.value ? 'Creating...' : 'Create' }}
        </button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.mag-overlay {
  position: fixed;
  inset: 0;
  background: var(--modal-overlay-bg);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 20;
  padding: 24px;
  --mag-text: var(--text);
  --mag-dim: var(--text-dim);
  --mag-accent: var(--accent);
  --mag-line: var(--line);
  --mag-panel: var(--panel);
  --mag-input: var(--bg-input);
  --mag-track: var(--progress-track);
  font-family: Inter, -apple-system, sans-serif;
}
.mag-frame {
  width: 820px;
  max-width: 100%;
  height: 560px;
  max-height: 90vh;
  background: var(--modal-surface);
  border: 1px solid var(--border);
  border-radius: 2px;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  box-shadow: var(--shadow-lg);
  color: var(--mag-text);
  font-size: 13px;
}
.mag-head {
  padding: 18px 22px 12px;
  border-bottom: 1px solid var(--mag-line);
  display: flex;
  align-items: baseline;
  gap: 12px;
}
.mag-head h2 {
  font-size: 17px;
  font-weight: 700;
  margin: 0;
}
.mag-step {
  margin-left: auto;
  font-size: 11px;
  color: var(--mag-dim);
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.mag-body {
  flex: 1;
  overflow: auto;
  padding: 16px 22px;
}
.mag-foot {
  display: flex;
  justify-content: flex-end;
  gap: 8px;
  padding: 12px 22px;
  border-top: 1px solid var(--mag-line);
}
.mag-btn {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  border-radius: 2px;
  font: inherit;
  font-size: 12.5px;
  font-weight: 600;
  padding: 7px 14px;
  cursor: pointer;
  border: 1px solid transparent;
  background: none;
  color: var(--mag-text);
}
.mag-btn.ghost {
  border-color: var(--mag-line);
  color: var(--mag-dim);
}
.mag-btn.ghost:hover { color: var(--mag-text); }
.mag-btn.primary {
  background: var(--mag-accent);
  color: var(--accent-text);
}
.mag-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.mag-error {
  margin-top: 12px;
  color: var(--red);
  font-size: 13px;
  background: var(--red-muted);
  padding: 8px 12px;
  border-radius: 2px;
}
</style>
