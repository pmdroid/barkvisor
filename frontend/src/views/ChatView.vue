<script setup lang="ts">
import { computed } from 'vue'
import ChatPanel from '../components/ChatPanel.vue'
import { useChatStore } from '../stores/chat'
import { HOME_LABEL } from '../utils/terminology'

const chat = useChatStore()
const chatReady = computed(() => chat.visible)
</script>

<template>
  <div class="ops-page">
    <div class="ops-toolbar">
      <h1>Chat</h1>
      <span class="ops-sub">Talk through this {{ HOME_LABEL }} Ollama proxy.</span>
    </div>
    <div class="ops-body split" style="padding:0;gap:0">
      <section class="convos">
        <div class="list-head">
          Conversations
          <button type="button" class="mini" disabled>New chat</button>
        </div>
        <div class="empty-list">No conversations.<br>Chats appear here once a model is available on this {{ HOME_LABEL }}.</div>
      </section>
      <section class="transcript">
        <template v-if="!chatReady">
          <div class="transcript-empty">
            <div class="t-icon">
              <svg width="22" height="22" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.2"><rect x="1" y="2" width="12" height="8" rx="1.5"/><path d="M4 10v2.5L6.5 10"/></svg>
            </div>
            <h2>No model to talk to</h2>
            <div class="hint"><b>Install Ollama and pull a model on a Device</b> and this transcript opens up.</div>
            <div class="grant">
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="7" cy="7" r="5.5"/><path d="M7 4.5v3l2 1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
              <b>{{ HOME_LABEL }} Ollama grant</b>
              <span class="sep"></span>
              <span>Completions use <span class="code">/v1/chat/completions</span></span>
            </div>
          </div>
          <div class="composer">
            <input type="text" placeholder="Select a model to start…" disabled>
            <button type="button" class="btn-ghost" disabled>Send</button>
          </div>
        </template>
        <ChatPanel v-else />
      </section>
    </div>
  </div>
</template>

<style scoped>
.transcript :deep(.chat-panel) {
  flex: 1;
  min-height: 0;
  border: 0;
  background: transparent;
  backdrop-filter: none;
}
.transcript-empty {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  text-align: center;
  padding: 24px;
}
.t-icon {
  width: 52px;
  height: 52px;
  border-radius: 50%;
  border: 1px dashed rgba(255,255,255,0.2);
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-dim);
  margin-bottom: 16px;
}
.transcript-empty h2 { font-size: 16px; font-weight: 700; letter-spacing: -0.01em; }
.hint { color: var(--text-dim); font-size: 12.5px; margin-top: 7px; max-width: 400px; line-height: 1.55; }
.hint b { color: var(--text); font-weight: 600; }
.composer {
  flex-shrink: 0;
  display: flex;
  gap: 8px;
  padding: 12px 16px;
  border-top: 1px solid var(--line);
}
.composer input {
  flex: 1;
  font: inherit;
  font-size: 12.5px;
  color: var(--text);
  background: rgba(255,255,255,0.04);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 9px 12px;
}
.list-head .mini { margin-left: auto; }
</style>
