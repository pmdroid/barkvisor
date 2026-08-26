<script setup lang="ts">
defineProps<{
  title: string
  subtitle?: string
  railTitle?: string
  maxWidth?: string
}>()

defineEmits<{ close: [] }>()
</script>

<template>
  <div class="modal-overlay" @click.self="$emit('close')">
    <div
      class="split-frame"
      :class="{ 'split-narrow': !$slots.rail }"
      :style="maxWidth ? { width: maxWidth, height: 'auto' } : undefined"
    >
      <aside v-if="$slots.rail" class="split-rail">
        <h3>{{ railTitle || title }}</h3>
        <slot name="rail" />
      </aside>
      <section class="split-stage">
        <div class="split-head">
          <h2>{{ title }}</h2>
          <p v-if="subtitle">{{ subtitle }}</p>
        </div>
        <div class="split-body">
          <slot />
        </div>
        <div v-if="$slots.actions" class="split-foot">
          <slot name="actions" />
        </div>
      </section>
    </div>
  </div>
</template>
