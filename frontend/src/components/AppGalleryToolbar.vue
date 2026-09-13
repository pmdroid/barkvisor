<script setup lang="ts">
import { computed } from 'vue'
import {
  appGalleryCategories,
  APP_GALLERY_ALL_CATEGORY,
  type AppGalleryFilterable,
} from '../utils/appGalleryFilter'

const props = defineProps<{
  apps: AppGalleryFilterable[]
}>()

const query = defineModel<string>('query', { default: '' })
const category = defineModel<string>('category', { default: APP_GALLERY_ALL_CATEGORY })

const chips = computed(() => appGalleryCategories(props.apps))

function selectCategory(name: string) {
  category.value = name
}
</script>

<template>
  <div class="agt">
    <div class="agt-search">
      <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="7" cy="7" r="4.5" /><path d="M10.5 10.5L14 14" /></svg>
      <input
        type="text"
        placeholder="Search apps"
        autocomplete="off"
        aria-label="Search apps"
        :value="query"
        @input="query = ($event.target as HTMLInputElement).value"
      />
    </div>
    <div class="agt-chips" role="group" aria-label="App categories">
      <button
        v-for="chip in chips"
        :key="chip.name"
        type="button"
        class="agt-chip"
        :class="{ on: chip.name === category }"
        :aria-pressed="chip.name === category ? 'true' : 'false'"
        @click="selectCategory(chip.name)"
      >
        {{ chip.name }}
        <span class="agt-n">{{ chip.count }}</span>
      </button>
    </div>
  </div>
</template>

<style scoped>
.agt-search {
  position: relative;
  margin-bottom: 12px;
}
.agt-search svg {
  position: absolute;
  left: 10px;
  top: 50%;
  transform: translateY(-50%);
  width: 13px;
  height: 13px;
  color: var(--text-dim);
  pointer-events: none;
}
.agt-search input {
  width: 100%;
  background: var(--bg-input, var(--panel));
  border: 1px solid var(--border);
  border-radius: 2px;
  color: var(--text);
  font-family: inherit;
  font-size: 13px;
  padding: 8px 10px 8px 30px;
  outline: none;
  box-sizing: border-box;
}
.agt-search input::placeholder {
  color: var(--text-dim);
}
.agt-search input:focus {
  border-color: rgba(0, 144, 248, 0.4);
}
.agt-chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-bottom: 14px;
}
.agt-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 4px 10px;
  background: transparent;
  border: 1px solid var(--border);
  border-radius: 2px;
  color: var(--text-secondary, var(--text-dim));
  font-family: inherit;
  font-size: 12px;
  cursor: pointer;
}
.agt-chip:hover {
  background: var(--panel);
  color: var(--text);
}
.agt-chip.on {
  background: rgba(0, 144, 248, 0.12);
  border-color: rgba(0, 144, 248, 0.45);
  color: var(--accent);
  font-weight: 500;
}
.agt-n {
  font-size: 10px;
  color: var(--text-dim);
}
.agt-chip.on .agt-n {
  color: rgba(0, 144, 248, 0.7);
}
</style>
