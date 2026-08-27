import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  chatDeltaFromSSELine,
  chatIsVisible,
  defaultChatModel,
  drainChatSSE,
  readChatSSE,
  streamChatCompletions,
} from './chatCompletions'

const here = dirname(fileURLToPath(import.meta.url))

describe('chat completions (PAS-270)', () => {
  test('chat page is gone', () => {
    const router = readFileSync(join(here, '../router/index.ts'), 'utf8')
    const app = readFileSync(join(here, '../App.vue'), 'utf8')
    expect(router).toContain("path: '/chat'")
    expect(router).toContain("redirect: '/dashboard'")
    expect(router).not.toContain('ChatView')
    expect(app).not.toContain('to="/chat"')
  })

  test('hides Chat without Ollama or models', () => {
    expect(chatIsVisible(false, 0)).toBe(false)
    expect(chatIsVisible(true, 0)).toBe(false)
    expect(chatIsVisible(false, 1)).toBe(false)
    expect(chatIsVisible(true, 1)).toBe(false)
  })

  test('prefers a running model then the first catalog name', () => {
    expect(defaultChatModel(['phi3', 'llama3'], ['llama3'])).toBe('llama3')
    expect(defaultChatModel(['phi3', 'llama3'], [])).toBe('phi3')
    expect(defaultChatModel([], [])).toBe('')
  })

  test('parses OpenAI SSE token lines', () => {
    expect(chatDeltaFromSSELine('data: {"choices":[{"delta":{"content":"Hi"}}]}')).toBe('Hi')
    expect(chatDeltaFromSSELine('data: [DONE]')).toBeNull()
    expect(chatDeltaFromSSELine(': keepalive')).toBeNull()
    expect(
      chatDeltaFromSSELine('data: {"choices":[{"message":{"content":"whole"}}]}'),
    ).toBe('whole')
  })

  test('drains a split SSE buffer and keeps a partial line', () => {
    const first = drainChatSSE('data: {"choices":[{"delta":{"content":"Hel"}}]}\ndata: {"choices":')
    expect(first.deltas).toEqual(['Hel'])
    expect(first.rest.startsWith('data: {"choices":')).toBe(true)
    const second = drainChatSSE(`${first.rest}[{"delta":{"content":"lo"}}]}\n`)
    expect(second.deltas).toEqual(['lo'])
  })

  test('readChatSSE yields tokens from a byte stream', async () => {
    const text =
      'data: {"choices":[{"delta":{"content":"A"}}]}\n\ndata: {"choices":[{"delta":{"content":"B"}}]}\n\ndata: [DONE]\n\n'
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(text.slice(0, 20)))
        controller.enqueue(new TextEncoder().encode(text.slice(20)))
        controller.close()
      },
    })
    const tokens: string[] = []
    await readChatSSE(stream, (t) => tokens.push(t))
    expect(tokens.join('')).toBe('AB')
  })

  test('streamChatCompletions posts stream true to /v1/chat/completions', async () => {
    const calls: { url: string; body: unknown; headers: Headers }[] = []
    const fetchImpl: typeof fetch = async (input, init) => {
      calls.push({
        url: String(input),
        body: JSON.parse(String(init?.body)),
        headers: new Headers(init?.headers),
      })
      const sse =
        'data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n'
      return new Response(sse, {
        status: 200,
        headers: { 'Content-Type': 'text/event-stream' },
      })
    }
    const tokens: string[] = []
    await streamChatCompletions({
      token: 'jwt-1',
      model: 'llama3:latest',
      messages: [{ role: 'user', content: 'hi' }],
      onDelta: (t) => tokens.push(t),
      fetchImpl,
    })
    expect(calls[0]?.url).toBe('/v1/chat/completions')
    expect(calls[0]?.body).toEqual({
      model: 'llama3:latest',
      stream: true,
      messages: [{ role: 'user', content: 'hi' }],
    })
    expect(calls[0]?.headers.get('Authorization')).toBe('Bearer jwt-1')
    expect(tokens.join('')).toBe('ok')
  })
})
