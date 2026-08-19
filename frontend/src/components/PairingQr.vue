<script setup lang="ts">
import { computed } from 'vue'
import { pairingQrSvg } from '../utils/pairingQr'

const props = defineProps<{ payload: string }>()

const svg = computed(() => pairingQrSvg(props.payload))
</script>

<template>
  <div
    v-if="svg"
    class="pairing-qr"
    role="img"
    aria-label="Pairing offer QR"
    v-html="svg"
  />
</template>

<style scoped>
.pairing-qr {
  display: flex;
  justify-content: center;
  margin: 16px 0 0;
}
.pairing-qr :deep(svg) {
  width: 196px;
  height: 196px;
  max-width: 100%;
  background: #fff;
  border-radius: var(--radius-xs, 6px);
}
</style>
