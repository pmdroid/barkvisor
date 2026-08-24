import { describe, expect, test } from 'bun:test'
import {
  CAGE_DNS_LINE,
  CAGE_OPENAI_BASE_URL,
  HOME_LISTEN_PORT,
  MISSING_INFERENCE_KEY,
  inferenceHowTo,
  inferenceHowToFromOrigin,
  lanCompletionsURL,
  lanListenHost,
  lanListenPort,
  lanOpenAIBaseURL,
} from './inferenceApiHowTo'

describe('inferenceApiHowTo (#212)', () => {
  test('self uses the connected Home origin on :7777, not Device :11434', () => {
    const input = {
      role: 'self' as const,
      originHost: '192.168.30.1',
      originPort: HOME_LISTEN_PORT,
      originScheme: 'http',
    }
    expect(lanListenHost(input)).toBe('192.168.30.1')
    expect(lanListenPort(input)).toBe(7777)
    expect(lanOpenAIBaseURL(input)).toBe('http://192.168.30.1:7777/v1')
    expect(lanCompletionsURL(input)).toBe('http://192.168.30.1:7777/v1/chat/completions')
    const howTo = inferenceHowTo(input)
    expect(howTo.curl).toContain('http://192.168.30.1:7777/v1/chat/completions')
    expect(howTo.curl).toContain("Authorization: Bearer <inference-key>")
    expect(howTo.env).toContain("export OPENAI_BASE_URL='http://192.168.30.1:7777/v1'")
    expect(howTo.env).toContain(`export OPENAI_API_KEY='${MISSING_INFERENCE_KEY}'`)
    expect(howTo.curl).not.toContain(':11434')
    expect(howTo.env).not.toContain(':11434')
  })

  test('member uses advertised host :7777, never origin port or :11434', () => {
    const input = {
      role: 'member' as const,
      originHost: '192.168.30.1',
      originPort: 8443,
      originScheme: 'https',
      memberHost: '10.0.0.8',
    }
    expect(lanListenHost(input)).toBe('10.0.0.8')
    expect(lanListenPort(input)).toBe(7777)
    expect(lanOpenAIBaseURL(input)).toBe('http://10.0.0.8:7777/v1')
    expect(lanCompletionsURL(input)).not.toContain(':11434')
    expect(lanCompletionsURL(input)).not.toContain(':8443')
    expect(lanCompletionsURL(input)).not.toContain(':7778')
  })

  test('member without host falls back to self origin', () => {
    const input = {
      role: 'member' as const,
      originHost: 'home.local',
      originPort: 7777,
      originScheme: 'http',
      memberHost: '  ',
    }
    expect(lanListenHost(input)).toBe('home.local')
    expect(lanOpenAIBaseURL(input)).toBe('http://home.local:7777/v1')
  })

  test('grant plaintext replaces the placeholder in curl and env', () => {
    const howTo = inferenceHowTo({
      role: 'self',
      originHost: '127.0.0.1',
      originPort: 7777,
      grantPlaintext: ' barkvisor_abc ',
    })
    expect(howTo.apiKey).toBe('barkvisor_abc')
    expect(howTo.curl).toContain('Authorization: Bearer barkvisor_abc')
    expect(howTo.env).toContain("export OPENAI_API_KEY='barkvisor_abc'")
    expect(howTo.cageEnv).toContain("export OPENAI_API_KEY='barkvisor_abc'")
  })

  test('in-cage block is slirp guestfwd 10.0.2.2:11434/v1 plus slirp DNS', () => {
    const howTo = inferenceHowTo({
      role: 'self',
      originHost: '192.168.30.1',
      originPort: 7777,
    })
    expect(howTo.cageBaseURL).toBe(CAGE_OPENAI_BASE_URL)
    expect(howTo.cageEnv).toContain("export OPENAI_BASE_URL='http://10.0.2.2:11434/v1'")
    expect(howTo.cageDnsLine).toBe(CAGE_DNS_LINE)
    expect(howTo.cageEnv).not.toContain('fd')
    expect(howTo.cageDnsLine.toLowerCase()).not.toContain('mtls')
    expect(howTo.cageDnsLine.toLowerCase()).not.toContain('cidr')
  })

  test('IPv6 origin host is bracketed; cage stays IPv4 slirp', () => {
    const howTo = inferenceHowTo({
      role: 'self',
      originHost: '2001:db8::1',
      originPort: 7777,
      originScheme: 'http',
    })
    expect(howTo.lanBaseURL).toBe('http://[2001:db8::1]:7777/v1')
    expect(howTo.cageBaseURL).toBe('http://10.0.2.2:11434/v1')
  })

  test('fromOrigin parses the connected Home and keeps member :7777', () => {
    const self = inferenceHowToFromOrigin('http://192.168.30.1:7777/models')
    expect(self.lanCompletionsURL).toBe('http://192.168.30.1:7777/v1/chat/completions')
    const member = inferenceHowToFromOrigin('https://home.example:8443', {
      role: 'member',
      memberHost: '10.0.0.8',
      grantPlaintext: 'barkvisor_abc',
    })
    expect(member.lanBaseURL).toBe('http://10.0.0.8:7777/v1')
    expect(member.curl).toContain('Bearer barkvisor_abc')
  })
})
