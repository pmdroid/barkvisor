import { ref, type Ref } from 'vue'
import api from '../api/client'
import type { TaskEvent } from '../api/types'

const MAX_CONSECUTIVE_ERRORS = 30

/**
 * Poll a background task until it reaches a terminal state.
 * Returns a reactive ref that updates as the task progresses.
 */
export function useTaskPoller() {
  const task: Ref<TaskEvent | null> = ref(null)
  const polling = ref(false)
  let timer: ReturnType<typeof setTimeout> | null = null
  let rejectPoll: ((error: Error) => void) | null = null

  async function poll(taskID: string, { interval = 1000, path, onComplete, onFailed }: {
    interval?: number
    /** Override GET path (member: /home/devices/:id/v1/tasks/:id). */
    path?: string
    onComplete?: (event: TaskEvent) => void
    onFailed?: (event: TaskEvent) => void
  } = {}): Promise<TaskEvent> {
    polling.value = true
    let consecutiveErrors = 0
    const url = path ?? `/tasks/${taskID}`

    return new Promise<TaskEvent>((resolve, reject) => {
      rejectPoll = reject
      const check = async () => {
        if (!polling.value) {
          rejectPoll = null
          reject(new Error('Task polling stopped'))
          return
        }
        try {
          const { data } = await api.get(url)
          task.value = data
          consecutiveErrors = 0

          if (data.status === 'completed' || data.status === 'failed' || data.status === 'cancelled') {
            polling.value = false
            rejectPoll = null
            if (data.status === 'completed') onComplete?.(data)
            else onFailed?.(data)
            resolve(data)
            return
          }
        } catch {
          consecutiveErrors++
          if (consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
            polling.value = false
            rejectPoll = null
            const errorEvent: TaskEvent = {
              taskID,
              kind: 'vmProvision' as TaskEvent['kind'],
              status: 'failed' as TaskEvent['status'],
              progress: null,
              error: 'Lost connection to task (too many consecutive errors)',
              resultPayload: null,
            }
            task.value = errorEvent
            onFailed?.(errorEvent)
            reject(new Error(`Task polling failed after ${MAX_CONSECUTIVE_ERRORS} consecutive errors`))
            return
          }
        }
        timer = setTimeout(check, interval)
      }
      check()
    })
  }

  function stop() {
    if (timer) {
      clearTimeout(timer)
      timer = null
    }
    polling.value = false
    const reject = rejectPoll
    rejectPoll = null
    reject?.(new Error('Task polling stopped'))
  }

  return { task, polling, poll, stop }
}
