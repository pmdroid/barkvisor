<script setup lang="ts">
import type { HomeTemplate } from '../../stores/homeLibrary'
import { templateIconPath, templateIconStyle } from '../../utils/templateIcons'

defineProps<{
  templates: HomeTemplate[]
  showCodingAgent: boolean
  selectedKind: string | null
  selectedTemplateSlug: string | null
}>()

const emit = defineEmits<{
  selectTemplate: [template: HomeTemplate]
  selectWindows: []
  selectCustom: []
  selectCodingAgent: []
}>()
</script>

<template>
  <div class="mag-shelf">
    <div
      v-for="template in templates"
      :key="template.slug"
      class="mag-card"
      :class="{ on: selectedKind === 'template' && selectedTemplateSlug === template.slug }"
      @click="emit('selectTemplate', template)"
    >
      <span class="mag-ic" :style="templateIconStyle(template.icon)">
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
          <path :d="templateIconPath(template.icon)" />
        </svg>
      </span>
      <b>{{ template.name }}</b>
      <span>{{ template.description || 'Ready-made VM template' }}</span>
    </div>
    <div
      v-if="showCodingAgent"
      class="mag-card"
      :class="{ on: selectedKind === 'coding-agent' }"
      @click="emit('selectCodingAgent')"
    >
      <span class="mag-ic" :style="templateIconStyle('code')">
        <svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
          <path d="M4 5.5 8 9l-4 3.5" />
          <path d="M9.5 12.5H14" />
        </svg>
      </span>
      <b>Coding Agent</b>
      <span>Sandboxed dev environment</span>
    </div>
    <div
      class="mag-card"
      :class="{ on: selectedKind === 'windows' }"
      @click="emit('selectWindows')"
    >
      <span class="mag-ic" :style="templateIconStyle('cloud')">
        <svg width="18" height="18" viewBox="0 0 18 18" fill="currentColor">
          <rect x="3" y="3" width="5.5" height="5.5" />
          <rect x="9.5" y="3" width="5.5" height="5.5" />
          <rect x="3" y="9.5" width="5.5" height="5.5" />
          <rect x="9.5" y="9.5" width="5.5" height="5.5" />
        </svg>
      </span>
      <b>Windows</b>
      <span>Windows 11 desktop</span>
    </div>
  </div>
  <div
    class="mag-custom"
    :class="{ on: selectedKind === 'custom' }"
    @click="emit('selectCustom')"
  >
    <svg width="15" height="15" viewBox="0 0 15 15" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round">
      <path d="M7.5 3v9M3 7.5h9" />
    </svg>
    Use your own image
    <span class="mag-custom-hint">Bring your own disk image</span>
  </div>
</template>

<style scoped>
.mag-shelf {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 10px;
}
.mag-card {
  border: 1px solid var(--mag-line, rgba(255, 255, 255, 0.07));
  border-radius: 2px;
  background: var(--mag-panel, rgba(255, 255, 255, 0.03));
  padding: 16px 14px;
  cursor: pointer;
  display: flex;
  flex-direction: column;
  gap: 9px;
}
.mag-card:hover { border-color: rgba(0, 144, 248, 0.5); }
.mag-card.on {
  border-color: var(--mag-accent, #0090f8);
  background: rgba(0, 144, 248, 0.08);
}
.mag-ic {
  width: 34px;
  height: 34px;
  border-radius: 8px;
  display: flex;
  align-items: center;
  justify-content: center;
}
.mag-card b { font-size: 13.5px; font-weight: 600; }
.mag-card span { font-size: 11.5px; color: var(--mag-dim, #6e6e6c); line-height: 1.4; }
.mag-custom {
  margin-top: 10px;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 11px 14px;
  border: 1px dashed var(--mag-line, rgba(255, 255, 255, 0.07));
  border-radius: 2px;
  color: var(--mag-dim, #6e6e6c);
  cursor: pointer;
  font-size: 12.5px;
}
.mag-custom:hover { color: var(--mag-text, #e4e4e2); border-color: rgba(255, 255, 255, 0.2); }
.mag-custom.on {
  border-color: var(--mag-accent, #0090f8);
  color: var(--mag-text, #e4e4e2);
  background: rgba(0, 144, 248, 0.05);
}
.mag-custom-hint { margin-left: auto; font-size: 11px; }
</style>
