import { getWSTicket } from '../api/client'

export interface TicketedEventSourceOptions {
  /** URL builder; called on every (re)connect with a fresh ticket. */
  url: (ticket: string) => string
  /** Optional vmID for ticket scoping (e.g. VM state stream). */
  vmID?: string | (() => string | undefined)
  onMessage?: (event: MessageEvent) => void
  onOpen?: () => void
  /** Called after giving up on reconnects (or when reconnect is disabled). */
  onError?: (error?: unknown) => void
  /** Reconnect with a fresh ticket after error. Default true. */
  reconnect?: boolean
  /** Initial reconnect delay ms. Default 1000. */
  initialDelayMs?: number
  /** Cap reconnect delay ms. Default 30000. */
  maxDelayMs?: number
  /** Stop after this many failed reconnects. Default 10. */
  maxAttempts?: number
}

/**
 * EventSource helper for ticketed SSE endpoints.
 *
 * Tickets are single-use and short-lived. The browser's native EventSource
 * retry reuses the same URL (same dead ticket) → 401 loops. This helper always
 * closes on error and reconnects with a **new** ticket + exponential backoff.
 */
export function useTicketedEventSource() {
  let es: EventSource | null = null
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null
  let delayMs = 1000
  let attempts = 0
  let stopped = true
  let generation = 0
  let options: TicketedEventSourceOptions | null = null

  function clearTimer() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer)
      reconnectTimer = null
    }
  }

  function closeSource() {
    if (es) {
      es.onopen = null
      es.onmessage = null
      es.onerror = null
      es.close()
      es = null
    }
  }

  async function connectOnce(gen: number) {
    if (!options || stopped || gen !== generation) return

    const vmID =
      typeof options.vmID === 'function' ? options.vmID() : options.vmID

    let ticket: string
    try {
      ticket = await getWSTicket(vmID)
    } catch (e) {
      if (stopped || gen !== generation) return
      if (options.reconnect === false) {
        options.onError?.(e)
        return
      }
      scheduleReconnect(gen)
      return
    }
    if (stopped || gen !== generation) return

    const url = options.url(ticket)
    const source = new EventSource(url)
    es = source

    source.onopen = () => {
      if (gen !== generation) return
      attempts = 0
      delayMs = options?.initialDelayMs ?? 1000
      options?.onOpen?.()
    }

    source.onmessage = (event) => {
      if (gen !== generation) return
      options?.onMessage?.(event)
    }

    source.onerror = () => {
      // Never leave EventSource to auto-retry with a spent ticket.
      closeSource()
      if (stopped || gen !== generation) return
      if (options?.reconnect === false) {
        options?.onError?.()
        return
      }
      scheduleReconnect(gen)
    }
  }

  function scheduleReconnect(gen: number) {
    if (!options || stopped || gen !== generation) return
    const maxAttempts = options.maxAttempts ?? 10
    attempts++
    if (attempts > maxAttempts) {
      options.onError?.(new Error('SSE reconnect attempts exhausted'))
      return
    }
    const maxDelay = options.maxDelayMs ?? 30_000
    const wait = delayMs
    delayMs = Math.min(delayMs * 2, maxDelay)
    clearTimer()
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null
      void connectOnce(gen)
    }, wait)
  }

  function start(opts: TicketedEventSourceOptions) {
    stop()
    options = opts
    stopped = false
    generation++
    attempts = 0
    delayMs = opts.initialDelayMs ?? 1000
    const gen = generation
    void connectOnce(gen)
  }

  function stop() {
    stopped = true
    generation++
    clearTimer()
    closeSource()
  }

  function isActive() {
    return !stopped && es !== null && es.readyState !== EventSource.CLOSED
  }

  return { start, stop, isActive }
}

export interface ImageProgressEvent {
  percent?: number
  bytesReceived?: number
  totalBytes?: number | null
  status?: string
  error?: string
}

/**
 * Thin wrapper for `/api/images/:id/progress` ticketed SSE.
 * Stops automatically on terminal `ready` / `error` status.
 */
export function useImageProgress() {
  const stream = useTicketedEventSource()

  function start(
    imageId: string,
    handlers: {
      onProgress?: (data: ImageProgressEvent) => void
      onReady?: (data: ImageProgressEvent) => void
      onError?: (data: ImageProgressEvent | undefined) => void
      onOpen?: () => void
    },
  ) {
    stream.start({
      url: (ticket) => `/api/images/${imageId}/progress?ticket=${ticket}`,
      reconnect: true,
      maxAttempts: 15,
      onOpen: () => handlers.onOpen?.(),
      onMessage: (event) => {
        let data: ImageProgressEvent
        try {
          data = JSON.parse(event.data) as ImageProgressEvent
        } catch {
          return
        }
        handlers.onProgress?.(data)
        if (data.status === 'ready') {
          stream.stop()
          handlers.onReady?.(data)
        } else if (data.status === 'error') {
          stream.stop()
          handlers.onError?.(data)
        }
      },
      onError: () => {
        handlers.onError?.(undefined)
      },
    })
  }

  return { start, stop: stream.stop, isActive: stream.isActive }
}
