<script setup lang="ts">
import ChatPanel from '../components/ChatPanel.vue'
import { HOME_LABEL } from '../utils/terminology'
</script>

<template>
  <div class="page-header">
    <div>
      <h1>Chat</h1>
      <p class="welcome-sub">Talk through this {{ HOME_LABEL }} Ollama proxy. Pick a model from the catalog.</p>
    </div>
  </div>
  <ChatPanel />
</template>
