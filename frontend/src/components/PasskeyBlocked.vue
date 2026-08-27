<script setup lang="ts">
import type { PasskeyBlock } from '../utils/webauthn'

defineProps<{ block: PasskeyBlock }>()
</script>

<template>
  <div class="passkey-blocked">
    <p class="reason">{{ block.reason }}</p>
    <pre class="fix">{{ block.fix }}</pre>
  </div>
</template>

<style scoped>
.passkey-blocked {
  border: 1px solid var(--line);
  border-radius: var(--radius);
  background: var(--bg-card);
  padding: 12px 14px;
  margin: 0 0 16px;
}
.reason {
  margin: 0 0 8px;
  font-size: 13px;
  color: var(--text);
  line-height: 1.45;
}
.fix {
  margin: 0;
  font-family: ui-monospace, 'SF Mono', Menlo, monospace;
  font-size: 12px;
  line-height: 1.5;
  color: var(--text-secondary);
  white-space: pre-wrap;
}
</style>
