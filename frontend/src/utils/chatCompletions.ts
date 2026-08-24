export interface ChatMessage {
  role: 'system' | 'user' | 'assistant'
  content: string
}

export function chatIsVisible(anyReachable: boolean, modelCount: number): boolean {
  return anyReachable && modelCount > 0
}

export function defaultChatModel(names: string[], running: string[]): string {
  if (running[0]) return running[0]
  return names[0] ?? ''
}

/** Pull OpenAI chat token text from one SSE line. */
export function chatDeltaFromSSELine(line: string): string | null {
  const trimmed = line.trim()
  if (!trimmed.startsWith('data:')) return null
  const payload = trimmed.slice(5).trim()
  if (!payload || payload === '[DONE]') return null
  try {
    const parsed = JSON.parse(payload) as {
      choices?: { delta?: { content?: unknown }; message?: { content?: unknown } }[]
    }
    const choice = parsed.choices?.[0]
    const delta = choice?.delta?.content
    if (typeof delta === 'string' && delta.length > 0) return delta
    const message = choice?.message?.content
    if (typeof message === 'string' && message.length > 0) return message
    return null
  } catch {
    return null
  }
}

export function drainChatSSE(buffer: string): { rest: string; deltas: string[] } {
  const deltas: string[] = []
  let rest = buffer
  let idx = rest.indexOf('\n')
  while (idx >= 0) {
    const line = rest.slice(0, idx)
    rest = rest.slice(idx + 1)
    const delta = chatDeltaFromSSELine(line)
    if (delta) deltas.push(delta)
    idx = rest.indexOf('\n')
  }
  return { rest, deltas }
}

export async function readChatSSE(
  stream: ReadableStream<Uint8Array>,
  onDelta: (text: string) => void,
  signal?: AbortSignal,
): Promise<void> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  try {
    while (!signal?.aborted) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      const drained = drainChatSSE(buffer)
      buffer = drained.rest
      for (const delta of drained.deltas) onDelta(delta)
    }
    buffer += decoder.decode()
    const drained = drainChatSSE(buffer.endsWith('\n') ? buffer : `${buffer}\n`)
    for (const delta of drained.deltas) onDelta(delta)
  } finally {
    reader.releaseLock()
  }
}

export async function streamChatCompletions(opts: {
  url?: string
  token: string
  model: string
  messages: ChatMessage[]
  onDelta: (text: string) => void
  signal?: AbortSignal
  fetchImpl?: typeof fetch
}): Promise<void> {
  const fetchImpl = opts.fetchImpl ?? fetch
  const res = await fetchImpl(opts.url ?? '/v1/chat/completions', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
      Authorization: `Bearer ${opts.token}`,
    },
    body: JSON.stringify({
      model: opts.model,
      stream: true,
      messages: opts.messages,
    }),
    signal: opts.signal,
  })
  if (!res.ok) {
    let reason = `Chat failed (${res.status})`
    try {
      const body = (await res.json()) as { reason?: string }
      if (body.reason) reason = body.reason
    } catch {
      // keep status text
    }
    throw new Error(reason)
  }
  if (!res.body) {
    throw new Error('Chat stream was empty')
  }
  await readChatSSE(res.body, opts.onDelta, opts.signal)
}
