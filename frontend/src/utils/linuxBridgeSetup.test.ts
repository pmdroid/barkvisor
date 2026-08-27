import { describe, expect, test } from 'bun:test'
import type { HostBridgeReadiness } from '../api/types'
import {
  BRIDGE_MUTATION_ACTION_KEYS,
  hostBridgeSetupPending,
  linuxBridgeSetupGroups,
  linuxBridgeStatusSummary,
  macosSocketVmnetSetupGroups,
  macosSocketVmnetStatusSummary,
  readinessAppliesTo,
  SOCKET_VMNET_INSTALL_COMMANDS,
} from './linuxBridgeSetup'

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
    for (const action of BRIDGE_MUTATION_ACTION_KEYS) {
      expect(groups.map((g) => g.id)).not.toContain(action)
    }
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

describe('macosSocketVmnetSetup', () => {
  test('fallback is copyable Homebrew commands, not mutation actions', () => {
    const groups = macosSocketVmnetSetupGroups(null)
    expect(groups.map((g) => g.id)).toEqual(['homebrew-socket-vmnet'])
    expect(groups[0].commands).toBe(SOCKET_VMNET_INSTALL_COMMANDS)
    expect(groups[0].commands).toContain('brew install socket_vmnet')
    expect(groups[0].commands).toContain('brew services start socket_vmnet')
    for (const action of BRIDGE_MUTATION_ACTION_KEYS) {
      expect(groups.map((g) => g.id)).not.toContain(action)
    }
  })

  test('server remediations win over local constants', () => {
    const groups = macosSocketVmnetSetupGroups(
      base({
        remediations: [{
          id: 'homebrew-socket-vmnet',
          label: 'Install and start socket_vmnet',
          commands: 'brew install socket_vmnet\nsudo brew services start socket_vmnet',
        }],
      }),
    )
    expect(groups.map((g) => g.id)).toEqual(['homebrew-socket-vmnet'])
    for (const action of BRIDGE_MUTATION_ACTION_KEYS) {
      expect(groups.map((g) => g.id)).not.toContain(action)
    }
  })

  test('ready Device has no command nag', () => {
    const groups = macosSocketVmnetSetupGroups(
      base({
        ready: true,
        remediations: [],
        bridges: [{ name: 'en0', enslaved: [] }],
      }),
    )
    expect(groups).toEqual([])
    for (const action of BRIDGE_MUTATION_ACTION_KEYS) {
      expect(groups.map((g) => g.id)).not.toContain(action)
    }
    expect(macosSocketVmnetStatusSummary(base({
      ready: true,
      bridges: [{ name: 'en0', enslaved: [] }],
    }))).toContain('ready')
  })

  test('missing facts keep a copyable guide', () => {
    expect(macosSocketVmnetStatusSummary(null)).toContain('socket_vmnet')
    expect(macosSocketVmnetStatusSummary(base({ ready: false }))).toContain('Homebrew')
  })
})

describe('hostBridgeSetupPending', () => {
  test('ready host with no Bridged network is not pending', () => {
    expect(hostBridgeSetupPending({
      supportsBridgedNetworking: true,
      hasBridgedNetwork: false,
      hostReady: true,
    })).toBe(false)
  })

  test('unknown or not-ready host without a Bridged network is pending', () => {
    expect(hostBridgeSetupPending({
      supportsBridgedNetworking: true,
      hasBridgedNetwork: false,
      hostReady: undefined,
    })).toBe(true)
    expect(hostBridgeSetupPending({
      supportsBridgedNetworking: true,
      hasBridgedNetwork: false,
      hostReady: false,
    })).toBe(true)
  })

  test('existing Bridged network or missing capability is not pending', () => {
    expect(hostBridgeSetupPending({
      supportsBridgedNetworking: true,
      hasBridgedNetwork: true,
      hostReady: false,
    })).toBe(false)
    expect(hostBridgeSetupPending({
      supportsBridgedNetworking: false,
      hasBridgedNetwork: false,
      hostReady: false,
    })).toBe(false)
  })
})

describe('readinessAppliesTo', () => {
  test('requires the snapshot Device, not a previous host', () => {
    expect(readinessAppliesTo('mac-1', 'mac-1')).toBe(true)
    expect(readinessAppliesTo('mac-1', 'linux-1')).toBe(false)
    expect(readinessAppliesTo('mac-1', null)).toBe(false)
    expect(readinessAppliesTo('mac-1', undefined)).toBe(false)
    expect(readinessAppliesTo('', '')).toBe(true)
  })

  test('Linux ↔ macOS mode change drops the shared snapshot', () => {
    expect(readinessAppliesTo('host-1', 'host-1', 'macos-guide', 'linux-guide')).toBe(false)
    expect(readinessAppliesTo('host-1', 'host-1', 'linux-guide', 'macos-guide')).toBe(false)
    expect(readinessAppliesTo('host-1', 'host-1', 'macos-guide', 'macos-guide')).toBe(true)
    expect(readinessAppliesTo('host-1', 'linux-1', 'macos-guide', 'linux-guide')).toBe(false)
  })
})
