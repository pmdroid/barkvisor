<script setup lang="ts">
import AppIcon from './AppIcon.vue'

defineProps<{
  icon?: string
  title: string
  subtitle?: string
}>()
</script>

<template>
  <div class="empty">
    <div v-if="icon" style="margin-bottom:16px">
      <AppIcon :name="icon" :size="48" style="opacity:0.4;stroke-width:1" />
    </div>
    <p>{{ title }}</p>
    <p v-if="subtitle" style="margin-top:4px;font-size:13px">{{ subtitle }}</p>
    <div v-if="$slots.default" style="margin-top:12px">
      <slot />
    </div>
  </div>
</template>
