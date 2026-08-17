<script setup lang="ts">
import { ref, watch } from 'vue'
import type { GuestCommandGroup } from '../../utils/guestAgentInstall'

const props = defineProps<{
  groups: GuestCommandGroup[]
  initialOpen?: string | null
}>()

const openId = ref<string | null>(props.initialOpen ?? null)

watch(
  () => props.initialOpen,
  (next) => {
    if (next && props.groups.some((group) => group.id === next)) {
      openId.value = next
    }
  },
)

function toggle(id: string) {
  openId.value = openId.value === id ? null : id
}
</script>

<template>
  <div class="guest-cmds">
    <div v-for="cmd in groups" :key="cmd.id" class="guest-cmd-group">
      <button type="button" class="guest-cmd-header" @click="toggle(cmd.id)">
        <span>{{ cmd.label }}</span>
        <svg
          :class="{ rotated: openId === cmd.id }"
          width="12"
          height="12"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2.5"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <polyline points="6 9 12 15 18 9" />
        </svg>
      </button>
      <div v-if="openId === cmd.id" class="guest-cmd-body">
        <pre><code>{{ cmd.commands }}</code></pre>
      </div>
    </div>
  </div>
</template>

<style scoped>
.guest-cmds {
  display: flex;
  flex-direction: column;
  gap: 1px;
  background: var(--border);
  border: 1px solid var(--border);
  border-radius: var(--radius-xs);
  overflow: hidden;
}
.guest-cmd-group {
  background: var(--bg);
}
.guest-cmd-header {
  width: 100%;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 10px 14px;
  font-size: 13px;
  font-weight: 600;
  color: var(--text-secondary);
  background: none;
  border: none;
  cursor: pointer;
  transition: background var(--transition);
}
.guest-cmd-header:hover {
  background: var(--bg-hover);
  color: var(--text);
}
.guest-cmd-header svg {
  transition: transform 0.2s ease;
  color: var(--text-dim);
}
.guest-cmd-header svg.rotated {
  transform: rotate(180deg);
}
.guest-cmd-body {
  padding: 0 14px 12px;
}
.guest-cmd-body pre {
  background: rgba(0, 0, 0, 0.3);
  border-radius: var(--radius-xs);
  padding: 10px 14px;
  margin: 0;
  overflow-x: auto;
}
.guest-cmd-body code {
  font-family: var(--font-mono);
  font-size: 12px;
  line-height: 1.7;
  color: var(--green);
  white-space: pre;
}
</style>
