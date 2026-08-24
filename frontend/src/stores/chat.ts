import { defineStore } from 'pinia'
import { computed, ref, watch } from 'vue'
import { useAuthStore } from './auth'
import { useOllamaStore } from './ollama'
import { isUnauthorizedError } from '../api/errors'
import {
  type ChatMessage,
  chatIsVisible,
  defaultChatModel,
  streamChatCompletions,
} from '../utils/chatCompletions'

export interface ChatTurn {
  id: number
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
  let nextTurnId = 1
  let streamGeneration = 0

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
    streamGeneration += 1
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
    streamGeneration += 1
    const generation = streamGeneration
    const assistantId = nextTurnId + 1
    draft.value = ''
    error.value = null
    messages.value = [
      ...messages.value,
      { id: nextTurnId++, role: 'user', content: text },
      { id: nextTurnId++, role: 'assistant', content: '' },
    ]
    streaming.value = true
    abort = new AbortController()
    const history: ChatMessage[] = messages.value
      .slice(0, -1)
      .map((turn) => ({ role: turn.role, content: turn.content }))
    const run = async () => {
      auth.hydrateFromStorage()
      await stream({
        token: auth.token,
        model: picked,
        messages: history,
        signal: abort.signal,
        onDelta: (delta) => {
          if (generation !== streamGeneration) return
          const idx = messages.value.findIndex((turn) => turn.id === assistantId)
          if (idx < 0) return
          messages.value[idx].content += delta
        },
      })
    }
    try {
      await run()
    } catch (err) {
      if ((err as { name?: string }).name === 'AbortError') return
      if (generation !== streamGeneration) return
      let failure: unknown = err
      if (isUnauthorizedError(err) && (await auth.refreshSession())) {
        try {
          await run()
          return
        } catch (retryErr) {
          if ((retryErr as { name?: string }).name === 'AbortError') return
          if (generation !== streamGeneration) return
          failure = retryErr
        }
      }
      error.value = failure instanceof Error ? failure.message : 'Chat failed'
      const idx = messages.value.findIndex((turn) => turn.id === assistantId)
      if (idx >= 0 && messages.value[idx].content === '') {
        const start = idx > 0 && messages.value[idx - 1].role === 'user' ? idx - 1 : idx
        messages.value = messages.value.slice(0, start)
        draft.value = text
      }
    } finally {
      if (generation === streamGeneration) {
        streaming.value = false
        abort = null
      }
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
