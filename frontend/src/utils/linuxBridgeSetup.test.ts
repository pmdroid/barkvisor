import { describe, expect, test } from 'bun:test'
import type { HostBridgeReadiness } from '../api/types'
import { linuxBridgeSetupGroups, linuxBridgeStatusSummary } from './linuxBridgeSetup'

function base(over: Partial<HostBridgeReadiness> = {}): HostBridgeReadiness {
  return {
    helperPath: '/usr/lib/qemu/qemu-bridge-helper',
    helperSetuid: false,
    suggestedBridge: 'br0',
    aclAllowsSuggested: false,
    bridges: [],
    defaultRouteInterface: 'eth0',
    onlyUplink: false,
    ready: false,
    ...over,
  }
}

describe('linuxBridgeSetup (PAS-222)', () => {
  test('ready Device has no command nag', () => {
    const groups = linuxBridgeSetupGroups(
      base({
        helperSetuid: true,
        aclAllowsSuggested: true,
        bridges: [{ name: 'br0', enslaved: ['enp2s0'] }],
        ready: true,
        onlyUplink: false,
      }),
    )
    expect(groups).toEqual([])
    expect(linuxBridgeStatusSummary(base({
      ready: true,
      bridges: [{ name: 'br0', enslaved: ['enp2s0'] }],
    }))).toContain('ready')
  })

  test('missing pieces get copyable steps', () => {
    const groups = linuxBridgeSetupGroups(base())
    expect(groups.map((g) => g.id)).toEqual(['create-bridge', 'allow-acl', 'setuid-helper'])
    expect(groups[0].commands).toContain('ip link add name br0')
  })

  test('server remediations win over local constants', () => {
    const groups = linuxBridgeSetupGroups(
      base({
        remediations: [{ id: 'allow-acl', label: 'Allow br0', commands: 'echo allow br0' }],
      }),
    )
    expect(groups.map((g) => g.id)).toEqual(['allow-acl'])
    expect(groups[0].commands).toBe('echo allow br0')
  })

  test('only-uplink warns instead of claiming ready', () => {
    expect(
      linuxBridgeStatusSummary(base({ onlyUplink: true, ready: false })),
    ).toContain('single uplink')
  })
})
