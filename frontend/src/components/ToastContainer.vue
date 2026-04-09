<script setup lang="ts">
import { useToastStore } from '../stores/toast'
import { useRouter } from 'vue-router'

const store = useToastStore()
const router = useRouter()

function navigate(to: string, id: number) {
  store.dismiss(id)
  router.push(to)
}
</script>

<template>
  <Teleport to="body">
    <div class="toast-container">
      <TransitionGroup name="toast">
        <div v-for="toast in store.toasts" :key="toast.id"
          class="toast" :class="toast.type"
          @click="store.dismiss(toast.id)">
          <div class="toast-icon">
            <svg v-if="toast.type === 'success'" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>
            <svg v-else-if="toast.type === 'error'" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><circle cx="12" cy="12" r="10"/><line x1="15" y1="9" x2="9" y2="15"/><line x1="9" y1="9" x2="15" y2="15"/></svg>
            <svg v-else width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="16" x2="12" y2="12"/><line x1="12" y1="8" x2="12.01" y2="8"/></svg>
          </div>
          <div class="toast-body">
            <span>{{ toast.message }}</span>
            <a v-if="toast.link" class="toast-link" @click.stop="navigate(toast.link.to, toast.id)">
              {{ toast.link.label }}
            </a>
          </div>
        </div>
      </TransitionGroup>
    </div>
  </Teleport>
</template>

<style scoped>
.toast-container {
  position: fixed;
  top: 16px;
  right: 16px;
  z-index: 9999;
  display: flex;
  flex-direction: column;
  gap: 8px;
  max-width: 380px;
}
.toast {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 12px 16px;
  border-radius: var(--radius);
  background: var(--overlay-bg);
  backdrop-filter: var(--glass-blur);
  border: 1px solid var(--border-glass);
  box-shadow: var(--shadow-lg);
  cursor: pointer;
  font-size: 13px;
  transition: all 0.3s ease;
}
.toast.success { border-left: 3px solid var(--green); }
.toast.error { border-left: 3px solid var(--red); }
.toast.info { border-left: 3px solid var(--accent); }
.toast-icon { flex-shrink: 0; padding-top: 1px; }
.toast.success .toast-icon { color: var(--green); }
.toast.error .toast-icon { color: var(--red); }
.toast.info .toast-icon { color: var(--accent); }
.toast-body {
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.toast-link {
  color: var(--accent);
  font-size: 12px;
  font-weight: 500;
  cursor: pointer;
  text-decoration: none;
}
.toast-link:hover { text-decoration: underline; }

.toast-enter-active { transition: all 0.3s ease; }
.toast-leave-active { transition: all 0.2s ease; }
.toast-enter-from { opacity: 0; transform: translateX(40px); }
.toast-leave-to { opacity: 0; transform: translateX(40px); }
</style>
