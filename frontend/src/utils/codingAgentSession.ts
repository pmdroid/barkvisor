import { isAgentWorkload } from './workloadClass'
import { HOME_OLLAMA_GRANT_URL, WEB_TERMINAL_PORT } from './codingAgentImage'

export const CODING_AGENT_GRANT = 'home-ollama'
export const CODING_AGENT_CHAT_PATH = '/v1/chat/completions'

export type CodingAgentSurface = 'chat' | 'terminal'

export function codingAgentTerminalPath(vmID: string): string {
  return `/api/vms/${vmID}/console`
}

export function isCodingAgentSession(raw: {
  name?: string | null
  workloadClass?: string | null
  spec?: { spec?: { workloadClass?: string | null } }
} | null | undefined): boolean {
  if (!raw) return false
  return isAgentWorkload(raw)
}

export function codingAgentSurfaces(raw: {
  name?: string | null
  workloadClass?: string | null
  spec?: { spec?: { workloadClass?: string | null } }
} | null | undefined): CodingAgentSurface[] {
  if (!isCodingAgentSession(raw)) return []
  return ['chat', 'terminal']
}

export function codingAgentEnv(grantPlaintext: string, openaiBaseURL = HOME_OLLAMA_GRANT_URL): Record<string, string> {
  return {
    OPENAI_BASE_URL: openaiBaseURL,
    OPENAI_API_KEY: grantPlaintext,
  }
}

export function codingAgentLoopbackHostfwd(hostPort: number, guestPort = WEB_TERMINAL_PORT): string {
  return `hostfwd=tcp:127.0.0.1:${hostPort}-:${guestPort}`
}

export function consoleTabLabel(raw: {
  name?: string | null
  workloadClass?: string | null
  spec?: { spec?: { workloadClass?: string | null } }
} | null | undefined): string {
  return isCodingAgentSession(raw) ? 'Terminal' : 'Console'
}

export const SESSION_NO_PUSH = 'NO PUSH'
export const SESSION_EXPIRY_ACTION = 'stop'

export function sessionWarningCopy(remainingSeconds: number | null | undefined): string {
  const minutes = Math.max(1, Math.ceil((remainingSeconds ?? 0) / 60))
  return minutes === 1
    ? 'Session expires in 1 minute. Push your changes. TTL stop keeps the disk.'
    : `Session expires in ${minutes} minutes. Push your changes. TTL stop keeps the disk.`
}

export function sessionIsLive(vmState: string | null | undefined): boolean {
  return vmState === 'running' || vmState === 'starting' || vmState === 'stopping'
}

export function sessionReceiptCopy(
  receipt: {
    stoppedAt: string
    lastGitPushAt?: string | null
    noPush: boolean
  } | null | undefined,
  vmState?: string | null,
): { stoppedAt: string; git: string; loud: boolean } | null {
  if (!receipt) return null
  if (sessionIsLive(vmState)) return null
  return {
    stoppedAt: receipt.stoppedAt,
    git: receipt.noPush || !receipt.lastGitPushAt ? SESSION_NO_PUSH : receipt.lastGitPushAt,
    loud: receipt.noPush || !receipt.lastGitPushAt,
  }
}
