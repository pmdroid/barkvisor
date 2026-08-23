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
