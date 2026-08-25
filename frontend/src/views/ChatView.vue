<script setup lang="ts">
import ChatPanel from '../components/ChatPanel.vue'
import { HOME_LABEL } from '../utils/terminology'
</script>

<template>
  <div class="ops-page">
    <div class="ops-toolbar">
      <h1>Chat</h1>
      <span class="ops-sub">Talk through this {{ HOME_LABEL }} Ollama proxy. Pick a model from the catalog.</span>
    </div>
    <div class="ops-body split">
      <section class="convos">
        <div class="list-head">Conversations</div>
        <div class="empty-list">No conversations</div>
      </section>
      <section class="transcript">
        <ChatPanel />
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
</style>
