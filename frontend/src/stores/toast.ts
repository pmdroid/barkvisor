import { defineStore } from 'pinia'
import { ref } from 'vue'

export interface Toast {
  id: number
  message: string
  type: 'success' | 'error' | 'info'
  link?: { label: string; to: string }
}

let nextId = 0

export const useToastStore = defineStore('toast', () => {
  const toasts = ref<Toast[]>([])
  const timers = new Map<number, ReturnType<typeof setTimeout>>()

  function show(message: string, opts: { type?: Toast['type']; link?: Toast['link']; duration?: number } = {}) {
    const id = nextId++
    const toast: Toast = { id, message, type: opts.type ?? 'info', link: opts.link }
    toasts.value.push(toast)
    const timer = setTimeout(() => dismiss(id), opts.duration ?? 5000)
    timers.set(id, timer)
  }

  function success(message: string, link?: Toast['link']) {
    show(message, { type: 'success', link })
  }

  function info(message: string) {
    show(message, { type: 'info' })
  }

  function error(message: string) {
    show(message, { type: 'error', duration: 8000 })
  }

  function dismiss(id: number) {
    const timer = timers.get(id)
    if (timer) {
      clearTimeout(timer)
      timers.delete(id)
    }
    toasts.value = toasts.value.filter(t => t.id !== id)
  }

  return { toasts, show, success, info, error, dismiss }
})
