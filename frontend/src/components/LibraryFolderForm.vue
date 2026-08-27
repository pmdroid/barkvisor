<script setup lang="ts">
import { onMounted, ref } from 'vue'
import api from '../api/client'
import { apiErrorMessage } from '../api/errors'
import { getSetupLibrary, saveSetupLibrary } from '../api/setup'
import type { LibrarySettings } from '../api/types'
import { bumpLibrarySettingsEpoch } from '../utils/librarySpace'
import { DEVICE_LABEL } from '../utils/terminology'
import FolderPicker from './FolderPicker.vue'
import AppButton from './ui/AppButton.vue'
import FormError from './ui/FormError.vue'

const props = defineProps<{
  source: 'system' | 'setup'
}>()
const emit = defineEmits<{
  saved: [LibrarySettings]
}>()

const draft = ref('')
const loading = ref(false)
const saving = ref(false)
const error = ref('')
const showPicker = ref(false)

onMounted(() => {
  void load()
})

async function load() {
  loading.value = true
  error.value = ''
  try {
    const data = props.source === 'setup'
      ? await getSetupLibrary()
      : (await api.get<LibrarySettings>('/system/library/settings')).data
    draft.value = data.imageDirectory
    if (!data.isDefault) emit('saved', data)
  } catch (e: unknown) {
    error.value = apiErrorMessage(e, 'Could not load Library path')
  } finally {
    loading.value = false
  }
}

async function save() {
  if (!draft.value.trim()) {
    error.value = 'Pick a folder'
    return
  }
  saving.value = true
  error.value = ''
  try {
    const data = props.source === 'setup'
      ? await saveSetupLibrary(draft.value.trim())
      : (await api.put<LibrarySettings>('/system/library/settings', {
          imageDirectory: draft.value.trim(),
        })).data
    draft.value = data.imageDirectory
    if (props.source === 'system') bumpLibrarySettingsEpoch()
    emit('saved', data)
  } catch (e: unknown) {
    error.value = apiErrorMessage(e, 'Could not save Library path')
  } finally {
    saving.value = false
  }
}
</script>

<template>
  <div class="lib-form">
    <p class="lead">
      Choose where this {{ DEVICE_LABEL }} stores images. Pick a folder, then save.
    </p>
    <div class="form-group">
      <label>Library folder</label>
      <div class="row">
        <input
          v-model="draft"
          :disabled="loading || saving"
          placeholder="/var/lib/barkvisor/images"
        />
        <AppButton size="sm" :disabled="loading || saving" @click="showPicker = true">
          Browse
        </AppButton>
      </div>
    </div>
    <FormError v-if="error" :message="error" />
    <div class="actions">
      <AppButton
        variant="primary"
        :loading="saving"
        loading-text="Saving..."
        :disabled="loading || !draft.trim()"
        @click="save"
      >
        Save folder
      </AppButton>
    </div>
    <FolderPicker
      v-if="showPicker"
      :model-value="draft"
      :source="source"
      @update:model-value="draft = $event"
      @close="showPicker = false"
    />
  </div>
</template>

<style scoped>
.lead {
  color: var(--text-secondary);
  font-size: 13px;
  margin: 0 0 16px;
}
.row {
  display: flex;
  gap: 8px;
  align-items: center;
}
.row input {
  flex: 1;
}
.actions {
  margin-top: 16px;
}
</style>
