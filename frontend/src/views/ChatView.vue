<script setup lang="ts">
import { nextTick, onMounted, ref, watch } from 'vue'
import AppButton from '../components/ui/AppButton.vue'
import EmptyState from '../components/ui/EmptyState.vue'
import { useChatStore } from '../stores/chat'
import { useOllamaStore } from '../stores/ollama'
import { HOME_LABEL } from '../utils/terminology'

const ollama = useOllamaStore()
const chat = useChatStore()
const scroller = ref<HTMLElement | null>(null)
const input = ref<HTMLTextAreaElement | null>(null)

onMounted(() => {
  void ollama.fetchCatalog()
  input.value?.focus()
})

watch(
  () => chat.messages.map((m) => m.content).join('\0'),
  async () => {
    await nextTick()
    if (scroller.value) scroller.value.scrollTop = scroller.value.scrollHeight
  },
)

function onKey(event: KeyboardEvent) {
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault()
    void chat.send()
  }
}
</script>

<template>
  <div class="page-header">
    <div>
      <h1>Chat</h1>
      <p class="welcome-sub">Talk through this {{ HOME_LABEL }} Ollama proxy. Pick a model from the catalog.</p>
    </div>
    <select v-if="chat.visible" v-model="chat.model" class="chat-model" :disabled="chat.streaming">
      <option v-for="name in chat.modelNames" :key="name" :value="name">{{ name }}</option>
    </select>
  </div>

  <EmptyState
    v-if="!chat.visible && !ollama.loading"
    icon="monitor"
    title="Chat is hidden"
    subtitle="Install Ollama and pull a model on a Device. Completions use /v1/chat/completions."
  />

  <div v-else class="chat-shell">
    <div ref="scroller" class="chat-log">
      <EmptyState
        v-if="chat.messages.length === 0"
        title="No messages yet"
        subtitle="Pick a model and send a prompt. Tokens stream as they arrive."
      />
      <div
        v-for="(turn, i) in chat.messages"
        :key="i"
        class="chat-turn"
        :class="turn.role === 'user' ? 'chat-user' : 'chat-assistant'"
      >
        <div class="chat-role">{{ turn.role === 'user' ? 'You' : chat.model }}</div>
        <div class="chat-body">{{ turn.content || (chat.streaming && i === chat.messages.length - 1 ? '…' : '') }}</div>
      </div>
    </div>
    <p v-if="chat.error" class="chat-error">{{ chat.error }}</p>
    <div class="chat-composer">
      <textarea
        ref="input"
        v-model="chat.draft"
        rows="2"
        placeholder="Message"
        :disabled="!chat.visible || !chat.model"
        @keydown="onKey"
      />
      <AppButton
        v-if="chat.streaming"
        variant="ghost"
        @click="chat.stop()"
      >
        Stop
      </AppButton>
      <AppButton
        v-else
        variant="primary"
        :disabled="!chat.draft.trim() || !chat.model"
        @click="chat.send()"
      >
        Send
      </AppButton>
    </div>
  </div>
</template>

<style scoped>
.chat-model {
  min-width: 180px;
}
.chat-shell {
  display: flex;
  flex-direction: column;
  min-height: calc(100vh - 160px);
  gap: 12px;
}
.chat-log {
  flex: 1;
  overflow: auto;
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 8px 0;
}
.chat-turn {
  max-width: 720px;
  padding: 12px 14px;
  border-radius: var(--radius);
  border: 1px solid var(--border-glass);
  background: var(--bg-card);
}
.chat-user {
  align-self: flex-end;
}
.chat-assistant {
  align-self: flex-start;
}
.chat-role {
  font-size: 11px;
  color: var(--text-dim);
  margin-bottom: 4px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.chat-body {
  white-space: pre-wrap;
  line-height: 1.45;
}
.chat-composer {
  display: flex;
  gap: 8px;
  align-items: flex-end;
}
.chat-composer textarea {
  flex: 1;
  resize: vertical;
  min-height: 52px;
}
.chat-error {
  color: var(--red);
  font-size: 13px;
  margin: 0;
}
</style>
