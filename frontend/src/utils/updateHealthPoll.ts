export type HealthPollResult = 'ok' | 'timeout' | 'failed'

export const consecutiveTaskMissesBeforeHealthPoll = 3

export async function pollUntilHealthy(opts: {
  health: () => Promise<boolean | 'failed'>
  now?: () => number
  sleep?: (ms: number) => Promise<void>
  intervalMs?: number
  timeoutMs?: number
}): Promise<HealthPollResult> {
  const interval = opts.intervalMs ?? 2000
  const timeout = opts.timeoutMs ?? 120_000
  const now = opts.now ?? Date.now
  const sleep = opts.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)))
  const started = now()
  while (now() - started <= timeout) {
    let signal: boolean | 'failed' = false
    try {
      signal = await opts.health()
    } catch {
      signal = false
    }
    if (signal === 'failed') return 'failed'
    if (signal) return 'ok'
    if (now() - started + interval > timeout) break
    await sleep(interval)
  }
  return 'timeout'
}
