export type HealthPollResult = 'ok' | 'timeout'

export async function pollUntilHealthy(opts: {
  health: () => Promise<boolean>
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
    try {
      if (await opts.health()) return 'ok'
    } catch {
      // Device is restarting.
    }
    if (now() - started + interval > timeout) break
    await sleep(interval)
  }
  return 'timeout'
}
