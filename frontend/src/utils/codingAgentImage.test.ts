import { describe, expect, test } from 'bun:test'
import {
  CODING_AGENT_SLUGS,
  DEVICE_OLLAMA_BASE_URL,
  codingAgentUserData,
  defaultWorkloadClassForImage,
  isCodingAgentImage,
  mergeCodingAgentUserData,
  normalizeOpenAIBaseURL,
} from './codingAgentImage'

describe('codingAgentImage (PAS-271)', () => {
  test('one image family: slugs for arm64 and x86_64, not two disk images', () => {
    expect(CODING_AGENT_SLUGS).toEqual(['coding-agent-arm64', 'coding-agent-x86_64'])
    expect(isCodingAgentImage({ name: 'Coding Agent', slug: 'coding-agent-arm64' })).toBe(true)
    expect(isCodingAgentImage({ name: 'Ubuntu 24.04 LTS', slug: 'ubuntu-24.04-arm64' })).toBe(false)
    expect(isCodingAgentImage({ name: 'my coding agent lab' })).toBe(false)
    expect(isCodingAgentImage({ name: 'Coding Agent', slug: 'ubuntu-24.04-arm64' })).toBe(false)
    expect(defaultWorkloadClassForImage({ name: 'Coding Agent' })).toBe('agent')
    expect(defaultWorkloadClassForImage({ name: 'Ubuntu' })).toBe('house')
  })

  test('OPENAI_BASE_URL presets: Device Ollama or BYO', () => {
    expect(DEVICE_OLLAMA_BASE_URL).toBe('http://10.0.2.2:11434/v1')
    expect(normalizeOpenAIBaseURL('')).toBe(DEVICE_OLLAMA_BASE_URL)
    expect(normalizeOpenAIBaseURL('https://api.openai.com/v1')).toBe('https://api.openai.com/v1')
    expect(() => normalizeOpenAIBaseURL('ftp://x')).toThrow()
    expect(() => normalizeOpenAIBaseURL('https://x y')).toThrow()
    expect(() => normalizeOpenAIBaseURL('https://x$(reboot).example/v1')).toThrow()
    expect(() => normalizeOpenAIBaseURL('https://x`id`.example/v1')).toThrow()
    expect(() => normalizeOpenAIBaseURL('https://x$HOME.example/v1')).toThrow()
  })

  test('user-data installs git, web terminal, coding-agent CLIs', () => {
    const yaml = codingAgentUserData(DEVICE_OLLAMA_BASE_URL)
    expect(yaml).toContain('git')
    expect(yaml).toContain('ttyd')
    expect(yaml).toContain('ttyd.service')
    expect(yaml).toContain('systemctl enable --now ttyd')
    expect(yaml).toContain('sha256sum -c')
    expect(yaml).toContain('/usr/local/bin')
    expect(yaml).toContain('claude.ai/install.sh')
    expect(yaml).toContain('opencode.ai/install')
    expect(yaml).toContain("OPENAI_BASE_URL='http://10.0.2.2:11434/v1'")
    expect(yaml).toContain('/etc/default/barkvisor-openai')
    expect(yaml).toContain('EnvironmentFile=-/etc/default/barkvisor-openai')
    expect(yaml).not.toContain('OPENAI_BASE_URL="http://')
  })

  test('merge keeps typed cloud-init and fills Device Ollama otherwise', () => {
    const img = { name: 'Coding Agent' }
    expect(mergeCodingAgentUserData('packages:\n  - vim\n', img, 'device-ollama', '')).toContain('vim')
    const injected = mergeCodingAgentUserData('', img, 'device-ollama', '')
    expect(injected).toContain('10.0.2.2:11434')
    const byo = mergeCodingAgentUserData('', img, 'byo', 'https://api.example/v1')
    expect(byo).toContain('https://api.example/v1')
    expect(mergeCodingAgentUserData('', { name: 'Ubuntu' }, 'device-ollama', '')).toBe('')
  })
})
