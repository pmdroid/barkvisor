import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  CAGE_DNS_LINE,
  CAGE_OPENAI_BASE_URL,
  HOME_LISTEN_PORT,
  MISSING_INFERENCE_KEY,
  advertiseHostName,
  formatDeviceURL,
  inferenceHowTo,
  inferenceHowToFromOrigin,
  isMagicDNSHost,
  lanCompletionsURL,
  lanListenHost,
  lanListenPort,
  lanOpenAIBaseURL,
  lanOrigin,
  preferredListenHost,
  tailnetListenHost,
} from './inferenceApiHowTo'

const here = dirname(fileURLToPath(import.meta.url))

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

  test('host precedence is saved advertise then tailnet then LAN origin', () => {
    expect(advertiseHostName('https://box.ts.net:443')).toBe('box.ts.net')
    expect(advertiseHostName('http://box.ts.net:7777/ignored')).toBe('box.ts.net')
    expect(advertiseHostName('100.64.1.2')).toBe('100.64.1.2')
    expect(tailnetListenHost({ available: true, dnsName: 'box.tailnet.ts.net', ip: '100.64.1.2' }))
      .toBe('box.tailnet.ts.net')
    expect(tailnetListenHost({ available: true, dnsName: null, ip: '100.64.1.2' })).toBe('100.64.1.2')
    expect(tailnetListenHost({ available: false, dnsName: 'stale.ts.net', ip: '100.64.1.2' })).toBe('')

    const advertised = {
      role: 'self' as const,
      originHost: '192.168.30.1',
      originPort: 8443,
      originScheme: 'https',
      advertiseHost: 'https://box.ts.net:443',
      tailnetHost: 'box.tailnet.ts.net',
    }
    expect(preferredListenHost(advertised)).toBe('box.ts.net')
    expect(lanListenHost(advertised)).toBe('box.ts.net')
    expect(lanListenPort(advertised)).toBe(7777)
    expect(lanOrigin(advertised)).toBe('https://box.ts.net')
    expect(lanOpenAIBaseURL(advertised)).toBe('https://box.ts.net/v1')
    expect(lanCompletionsURL(advertised)).toBe('https://box.ts.net/v1/chat/completions')
    expect(lanOrigin(advertised)).not.toContain(':443')

    const tailnet = {
      role: 'self' as const,
      originHost: '192.168.30.1',
      originPort: HOME_LISTEN_PORT,
      originScheme: 'http',
      advertiseHost: '  ',
      tailnetHost: '100.64.1.2',
    }
    expect(lanOpenAIBaseURL(tailnet)).toBe('http://100.64.1.2:7777/v1')

    const lan = inferenceHowToFromOrigin('http://192.168.30.1:7777', { role: 'self' })
    expect(lan.lanBaseURL).toBe('http://192.168.30.1:7777/v1')
    expect(lan.cageBaseURL).toBe(CAGE_OPENAI_BASE_URL)
    expect(lan.cageBaseURL).toBe('http://10.0.2.2:11434/v1')
    expect(lan.env).not.toContain(':11434')
    expect(lan.cageEnv).toContain("export OPENAI_BASE_URL='http://10.0.2.2:11434/v1'")

    const models = readFileSync(join(here, '../views/ModelsView.vue'), 'utf8')
    expect(models).toContain('advertiseHost')
    expect(models).toContain('tailnetListenHost')
    expect(models).toContain("api.get<RemoteAccessStatus>('/system/remote-access')")
    expect(lan.cageBaseURL).toBe('http://10.0.2.2:11434/v1')
    expect(models).not.toContain('CAGE_OPENAI_BASE_URL')
    expect(models).not.toContain('howTo.cageBaseURL')
    expect(models).toContain('howTo.lanCompletionsURL')
  })

  test('Device URL display is https MagicDNS without a port', () => {
    expect(isMagicDNSHost('box.tailnet.ts.net')).toBe(true)
    expect(isMagicDNSHost('box.tailscale.net')).toBe(true)
    expect(isMagicDNSHost('192.168.0.4')).toBe(false)
    expect(formatDeviceURL('box.tailnet.ts.net')).toBe('https://box.tailnet.ts.net')
    expect(formatDeviceURL('https://box.tailnet.ts.net:443')).toBe('https://box.tailnet.ts.net')
    expect(formatDeviceURL('192.168.0.4')).toBe('http://192.168.0.4:7777')
    expect(formatDeviceURL('box.tailnet.ts.net')).not.toContain(':7777')
    expect(formatDeviceURL('box.tailnet.ts.net')).not.toContain(':443')
    expect(formatDeviceURL('')).toBe('')
    expect(formatDeviceURL(null)).toBe('')

    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain('formatDeviceURL')
    expect(settings).toContain('tailscale?.available')
    expect(settings).not.toContain('http://${formatListenHost(host)}:7777')
  })
})
