import { describe, expect, test } from 'bun:test'
import { HOME_OLLAMA_GRANT_URL } from './codingAgentImage'
import {
  CODING_AGENT_CHAT_PATH,
  CODING_AGENT_GRANT,
  codingAgentEnv,
  codingAgentLoopbackHostfwd,
  codingAgentSurfaces,
  codingAgentTerminalPath,
  consoleTabLabel,
  isCodingAgentSession,
  SESSION_EXPIRY_ACTION,
  SESSION_NO_PUSH,
  sessionReceiptCopy,
  sessionWarningCopy,
} from './codingAgentSession'

describe('codingAgentSession (PAS-272)', () => {
  const coder = { name: 'Coding Agent', workloadClass: 'agent' }

  test('start: coding image plus agent cage', () => {
    expect(isCodingAgentSession(coder)).toBe(true)
    expect(isCodingAgentSession({ name: 'Coding Agent', workloadClass: 'house' })).toBe(false)
    expect(isCodingAgentSession({ name: 'scratch', workloadClass: 'agent' })).toBe(true)
    expect(codingAgentSurfaces(coder)).toEqual(['chat', 'terminal'])
    expect(codingAgentSurfaces({ name: 'Ubuntu', workloadClass: 'house' })).toEqual([])
  })

  test('proxy: Home chat and serial terminal', () => {
    expect(CODING_AGENT_GRANT).toBe('home-ollama')
    expect(CODING_AGENT_CHAT_PATH).toBe('/v1/chat/completions')
    expect(codingAgentTerminalPath('vm-1')).toBe('/api/vms/vm-1/console')
    expect(codingAgentLoopbackHostfwd(17681)).toBe('hostfwd=tcp:127.0.0.1:17681-:7681')
    expect(consoleTabLabel(coder)).toBe('Terminal')
    expect(consoleTabLabel({ name: 'haos', workloadClass: 'house' })).toBe('Console')
  })

  test('env: OPENAI_BASE_URL is the Home Ollama grant', () => {
    expect(HOME_OLLAMA_GRANT_URL).toBe('http://10.0.2.2:11434/v1')
    expect(codingAgentEnv('barkvisor_abc')).toEqual({
      OPENAI_BASE_URL: HOME_OLLAMA_GRANT_URL,
      OPENAI_API_KEY: 'barkvisor_abc',
    })
  })

  test('PAS-273: TTL stop, 15-minute warning, NO PUSH receipt', () => {
    expect(SESSION_EXPIRY_ACTION).toBe('stop')
    expect(SESSION_NO_PUSH).toBe('NO PUSH')
    expect(sessionWarningCopy(15 * 60)).toBe('Session expires in 15 minutes. TTL stop keeps the disk.')
    expect(sessionWarningCopy(60)).toBe('Session expires in 1 minute. TTL stop keeps the disk.')
    expect(sessionReceiptCopy({
      stoppedAt: '2026-08-23T12:00:00Z',
      lastGitPushAt: null,
      noPush: true,
    })).toEqual({
      stoppedAt: '2026-08-23T12:00:00Z',
      git: 'NO PUSH',
      loud: true,
    })
    expect(sessionReceiptCopy({
      stoppedAt: '2026-08-23T12:00:00Z',
      lastGitPushAt: '2026-08-23T11:00:00Z',
      noPush: false,
    })?.loud).toBe(false)
  })
})
