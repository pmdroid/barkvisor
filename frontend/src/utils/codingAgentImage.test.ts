import { describe, expect, test } from 'bun:test'
import {
  ALLOW_HOST_OLLAMA_YAML,
  CLAUDE_SHA256_AARCH64,
  CODING_AGENT_SLUGS,
  DEVICE_OLLAMA_BASE_URL,
  OPENCODE_SHA256_AARCH64,
  codingAgentUserData,
  defaultWorkloadClassForImage,
  isCodingAgentImage,
  mergeCodingAgentUserData,
  normalizeOpenAIBaseURL,
  openaiAPIKeyFromUserData,
  usesDeviceOllama,
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
    expect(() => normalizeOpenAIBaseURL('https://x.test/$(id)')).toThrow()
    expect(() => normalizeOpenAIBaseURL('https://x.test/`id`')).toThrow()
    expect(() => normalizeOpenAIBaseURL('http://10.0.2.2:11434@evil.com/v1')).toThrow()
    expect(usesDeviceOllama(DEVICE_OLLAMA_BASE_URL)).toBe(true)
    expect(usesDeviceOllama('http://10.0.2.2:11434@evil.com/v1')).toBe(false)
    expect(() => normalizeOpenAIBaseURL('https://x$(reboot).example/v1')).toThrow()
    expect(() => normalizeOpenAIBaseURL('https://x`id`.example/v1')).toThrow()
    expect(() => normalizeOpenAIBaseURL('https://x$HOME.example/v1')).toThrow()
    expect(() => normalizeOpenAIBaseURL('http:example.com/v1')).toThrow()
  })

  test('user-data installs git, web terminal, coding-agent CLIs', () => {
    const yaml = codingAgentUserData(DEVICE_OLLAMA_BASE_URL)
    expect(yaml).toContain('git')
    expect(yaml).toContain('ttyd')
    expect(yaml).toContain('ttyd.service')
    expect(yaml).toContain('systemctl enable --now ttyd')
    expect(yaml).toContain('sha256sum -c')
    expect(yaml).toContain('/usr/local/bin')
    expect(yaml).not.toContain('export OPENAI_BASE_URL="')
    expect(yaml).toContain("export OPENAI_BASE_URL='http://10.0.2.2:11434/v1'")
    expect(yaml).toContain("export OPENAI_API_KEY='ollama'")
    expect(yaml).toContain("permissions: '0600'")
    expect(yaml).toContain('chown ubuntu:ubuntu /etc/default/barkvisor-openai')
    const byoKey = codingAgentUserData('https://api.example/v1', 'sk-test')
    expect(byoKey).toContain("export OPENAI_API_KEY='sk-test'")
    expect(byoKey).toContain('OPENAI_API_KEY=sk-test')
    expect(yaml).toContain(ALLOW_HOST_OLLAMA_YAML)
    expect(yaml).not.toContain('# barkvisor:allow-host-ollama')
    expect(yaml).toContain(CLAUDE_SHA256_AARCH64)
    expect(yaml).toContain(OPENCODE_SHA256_AARCH64)
    expect(yaml).toContain('anthropics/claude-code/releases')
    expect(yaml).toContain('anomalyco/opencode/releases')
    expect(yaml).not.toContain('claude.ai/install.sh')
    expect(yaml).not.toContain('opencode.ai/install')
    expect(yaml).not.toContain('| bash')
    expect(yaml).toContain('/etc/git-hooks/pre-push')
    expect(yaml).toContain('/var/lib/barkvisor/last-git-push')
    const spoof = codingAgentUserData('http://10.0.2.2:11434@evil.com/v1')
    expect(spoof).not.toContain(ALLOW_HOST_OLLAMA_YAML)
  })

  test('merge keeps typed cloud-init and fills Device Ollama otherwise', () => {
    const img = { name: 'Coding Agent' }
    expect(mergeCodingAgentUserData('packages:\n  - vim\n', img, 'device-ollama', '')).toContain('vim')
    const injected = mergeCodingAgentUserData('', img, 'device-ollama', '')
    expect(injected).toContain('10.0.2.2:11434')
    expect(() => mergeCodingAgentUserData('', img, 'byo', 'https://api.example/v1')).toThrow()
    const byo = mergeCodingAgentUserData('', img, 'byo', 'https://api.example/v1', 'sk-test')
    expect(byo).toContain('https://api.example/v1')
    expect(byo).toContain("export OPENAI_API_KEY='sk-test'")
    expect(mergeCodingAgentUserData('', { name: 'Ubuntu' }, 'device-ollama', '')).toBe('')
    const granted = mergeCodingAgentUserData('', img, 'home-ollama', '', '', 'barkvisor_abc')
    expect(granted).toContain("export OPENAI_API_KEY='barkvisor_abc'")
    expect(granted).toContain('OPENAI_API_KEY=barkvisor_abc')
    expect(granted).not.toContain("export OPENAI_API_KEY='ollama'")
    expect(openaiAPIKeyFromUserData(granted)).toBe('barkvisor_abc')
    expect(openaiAPIKeyFromUserData(injected)).toBe('ollama')
  })
})
