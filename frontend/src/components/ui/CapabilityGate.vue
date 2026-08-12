<script setup lang="ts">
import { useFeature } from '../../composables/useFeature'
import UnsupportedHint from './UnsupportedHint.vue'

const props = defineProps<{
  feature: string
}>()

const gate = useFeature(() => props.feature)
</script>

<template>
  <div class="capability-gate">
    <slot :available="gate.available" :explanation="gate.explanation" />
    <UnsupportedHint v-if="!gate.available" :text="gate.explanation" />
  </div>
</template>
