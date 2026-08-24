import { describe, expect, test } from 'bun:test'
import { parseSystemAbout } from './systemAbout'

describe('parseSystemAbout', () => {
  test('decodes version platform arch accelerator uptime and ignores licenses', () => {
    const about = parseSystemAbout({
      version: '0.4.0',
      platform: 'macOS',
      hostArch: 'arm64',
      accelerator: 'hvf',
      processUptimeSeconds: 12.9,
      licenses: [{ name: 'QEMU', license: 'GPL-2.0' }],
    })
    expect(about).toEqual({
      version: '0.4.0',
      platform: 'macOS',
      hostArch: 'arm64',
      accelerator: 'hvf',
      processUptimeSeconds: 12,
    })
  })

  test('rejects incomplete payloads instead of inventing numbers', () => {
    expect(parseSystemAbout(null)).toBeNull()
    expect(parseSystemAbout({})).toBeNull()
    expect(parseSystemAbout({
      version: '0.4.0',
      platform: 'Linux',
      hostArch: 'x86_64',
      accelerator: 'kvm',
    })).toBeNull()
    expect(parseSystemAbout({
      version: '0.4.0',
      platform: 'Linux',
      hostArch: 'x86_64',
      accelerator: 'kvm',
      processUptimeSeconds: '12',
    })).toBeNull()
  })
})
