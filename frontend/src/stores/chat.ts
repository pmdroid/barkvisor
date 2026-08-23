import { defineStore } from 'pinia'
import { computed, ref, watch } from 'vue'
import { useAuthStore } from './auth'
import { useOllamaStore } from './ollama'
import {
  type ChatMessage,
  chatIsVisible,
  defaultChatModel,
  streamChatCompletions,
} from '../utils/chatCompletions'

export interface ChatTurn {
  role: 'user' | 'assistant'
  content: string
}

export const useChatStore = defineStore('chat', () => {
  const auth = useAuthStore()
  const ollama = useOllamaStore()
  const messages = ref<ChatTurn[]>([])
  const model = ref('')
  const draft = ref('')
  const streaming = ref(false)
  const error = ref<string | null>(null)
  let abort: AbortController | null = null

  const visible = computed(() => chatIsVisible(ollama.anyReachable, ollama.models.length))
  const modelNames = computed(() => ollama.models.map((row) => row.name))
  const runningNames = computed(() => ollama.models.filter((row) => row.running).map((row) => row.name))

  watch(
    [modelNames, runningNames],
    () => {
      if (!model.value || !modelNames.value.includes(model.value)) {
        model.value = defaultChatModel(modelNames.value, runningNames.value)
      }
    },
    { immediate: true },
  )

  function stop() {
    abort?.abort()
    abort = null
    streaming.value = false
  }

  function clear() {
    stop()
    messages.value = []
    error.value = null
  }

  async function send(
    stream: typeof streamChatCompletions = streamChatCompletions,
  ): Promise<void> {
    const text = draft.value.trim()
    const picked = model.value.trim()
    if (!text || !picked || streaming.value) return
    draft.value = ''
    error.value = null
    messages.value = [...messages.value, { role: 'user', content: text }, { role: 'assistant', content: '' }]
    streaming.value = true
    abort = new AbortController()
    const history: ChatMessage[] = messages.value
      .slice(0, -1)
      .map((turn) => ({ role: turn.role, content: turn.content }))
    try {
      await stream({
        token: auth.token,
        model: picked,
        messages: history,
        signal: abort.signal,
        onDelta: (delta) => {
          const last = messages.value[messages.value.length - 1]
          if (!last || last.role !== 'assistant') return
          messages.value = [
            ...messages.value.slice(0, -1),
            { role: 'assistant', content: last.content + delta },
          ]
        },
      })
    } catch (err) {
      if ((err as { name?: string }).name === 'AbortError') return
      error.value = err instanceof Error ? err.message : 'Chat failed'
      const last = messages.value[messages.value.length - 1]
      if (last?.role === 'assistant' && last.content === '') {
        messages.value = messages.value.slice(0, -2)
        draft.value = text
      }
    } finally {
      streaming.value = false
      abort = null
    }
  }

  return {
    messages,
    model,
    draft,
    streaming,
    error,
    visible,
    modelNames,
    send,
    stop,
    clear,
  }
})
