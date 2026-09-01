import { describe, expect, test } from 'bun:test'
import type { HostBridgeReadiness } from '../api/types'
import {
  BRIDGE_MUTATION_ACTION_KEYS,
  buildLinuxBridgeApplyBody,
  hostBridgeCanApply,
  hostBridgeSetupPending,
  linuxBridgeApplyCommands,
  linuxBridgeCanApply,
  macosSocketVmnetCanManage,
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
    expect(groups[0].commands).toContain('/api/system/bridges')
    expect(groups[0].commands).toContain('Apply')
    expect(groups[0].commands).not.toContain('ip link add')
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
  test('fallback includes socket_vmnet install and networksetup examples', () => {
    const groups = macosSocketVmnetSetupGroups(null)
    expect(groups.map((g) => g.id)).toEqual(['homebrew-socket-vmnet', 'device-address'])
    expect(groups[0].commands).toContain('brew install socket_vmnet')
    expect(groups[1].commands).toContain('/api/system/bridges')
    expect(groups[1].commands).toContain('networksetup -listallhardwareports')
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
          commands: 'brew install socket_vmnet',
        }],
      }),
    )
    expect(groups.map((g) => g.id)).toEqual(['homebrew-socket-vmnet'])
    for (const action of BRIDGE_MUTATION_ACTION_KEYS) {
      expect(groups.map((g) => g.id)).not.toContain(action)
    }
  })

  test('ready Device still shows address commands when no server remediations', () => {
    const groups = macosSocketVmnetSetupGroups(
      base({
        ready: true,
        remediations: [],
        bridges: [{ name: 'en0', enslaved: [] }],
      }),
    )
    expect(groups.map((g) => g.id)).toEqual(['device-address'])
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

describe('linuxBridgeApply', () => {
  test('apply hints stay API-first (not guest addressing)', () => {
    const cmds = linuxBridgeApplyCommands(base())
    expect(cmds.join('\n')).toContain('/api/system/bridges')
    expect(cmds.join('\n')).toContain('Keep changes')
    expect(cmds.join('\n')).toContain('"bridge"')
    expect(cmds.join('\n')).toContain('Create → Bridge')
    expect(cmds.join('\n')).not.toContain('select eth0 → Apply')
    expect(cmds.join('\n')).not.toContain('guest static')
  })

  test('apply is available on Linux host mutation', () => {
    expect(linuxBridgeCanApply({ supportsHostMutation: true })).toBe(true)
    expect(linuxBridgeCanApply({ platform: 'Linux' })).toBe(true)
    expect(linuxBridgeCanApply({ supportsHostBridgeManagement: true })).toBe(true)
    expect(linuxBridgeCanApply({ platform: 'macOS', supportsHostMutation: true })).toBe(false)
    expect(linuxBridgeCanApply({ platform: 'macOS', supportsHostMutation: false })).toBe(false)
  })

  test('macOS socket_vmnet manage is Mac only', () => {
    expect(macosSocketVmnetCanManage({ platform: 'macOS' })).toBe(true)
    expect(macosSocketVmnetCanManage({ platform: 'darwin', supportsManagedBridgeDaemon: true })).toBe(true)
    expect(macosSocketVmnetCanManage({ supportsManagedBridgeDaemon: true })).toBe(true)
    expect(macosSocketVmnetCanManage({ platform: 'Linux', supportsManagedBridgeDaemon: false })).toBe(false)
    expect(macosSocketVmnetCanManage({ platform: 'Linux', supportsHostMutation: true })).toBe(false)
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

  test('hostBridgeCanApply is true on macOS with managed bridge + host mutation', () => {
    expect(hostBridgeCanApply({
      platform: 'macos',
      supportsHostMutation: true,
      supportsManagedBridgeDaemon: true,
    })).toBe(true)
    expect(linuxBridgeCanApply({ platform: 'macos', supportsHostMutation: true })).toBe(false)
  })

  test('buildLinuxBridgeApplyBody sends dhcp or static host fields', () => {
    expect(buildLinuxBridgeApplyBody({
      nic: 'eth0',
      addressing: 'dhcp',
      confirm: false,
    })).toEqual({
      interface: 'eth0',
      action: 'apply',
      addressing: 'dhcp',
      confirm: false,
    })
    expect(buildLinuxBridgeApplyBody({
      nic: 'eth0',
      addressing: 'static',
      address: ' 192.168.1.10/24 ',
      gateway: ' 192.168.1.1 ',
      dns: '1.1.1.1, 8.8.8.8',
      confirm: true,
    })).toEqual({
      interface: 'eth0',
      action: 'apply',
      addressing: 'static',
      address: '192.168.1.10/24',
      gateway: '192.168.1.1',
      dns: ['1.1.1.1', '8.8.8.8'],
      confirm: true,
    })
  })
})
