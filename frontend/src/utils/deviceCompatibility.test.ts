import { describe, expect, test } from 'bun:test'
import type { CurrentHostCapabilities, HomeDeviceHealthSnapshot, VMTemplate } from '../api/types'
import { defaultCapabilities } from './capabilitiesParse'
import {
  createVMIncompatibilityReasons,
  guestTypesSupportWindows,
  templateIncompatibilityReasons,
  toPickOption,
} from './deviceCompatibility'

function device(
  partial: Partial<HomeDeviceHealthSnapshot> & Pick<HomeDeviceHealthSnapshot, 'hostId' | 'role'>,
): HomeDeviceHealthSnapshot {
  return {
    agentPort: 7778,
    reachability: 'ok',
    platform: { os: 'macOS', arch: 'arm64' },
    ...partial,
  }
}

const armCaps: CurrentHostCapabilities = {
  platform: 'macOS',
  supportsBridgedNetworking: true,
  supportsManagedBridgeDaemon: true,
  supportsUSBPassthrough: true,
  supportsInAppUpdate: true,
  accelerator: 'hvf',
  hostArch: 'arm64',
  hostCpuCount: 8,
  runnableArches: ['arm64'],
  details: [],
}

const x86Caps: CurrentHostCapabilities = {
  ...armCaps,
  platform: 'Linux',
  supportsBridgedNetworking: false,
  hostArch: 'x86_64',
  runnableArches: ['x86_64'],
}

const template = (partial: Partial<VMTemplate> = {}): VMTemplate => ({
  id: 't1',
  slug: 'ubuntu',
  name: 'Ubuntu',
  description: null,
  category: 'general',
  icon: 'terminal',
  imageSlug: 'ubuntu-24.04-arm64',
  cpuCount: 2,
  memoryMB: 1024,
  diskSizeGB: 10,
  portForwards: null,
  networkMode: 'nat',
  inputs: [],
  userDataTemplate: '',
  isBuiltIn: true,
  repositoryId: 'r1',
  architectures: ['arm64'],
  ...partial,
})

describe('deviceCompatibility (PAS-34)', () => {
  test('unreachable members are disabled; self stays selectable', () => {
    const self = device({ hostId: 'desk', role: 'self', reachability: 'unreachable' })
    const peer = device({ hostId: 'studio', role: 'member', reachability: 'unreachable' })
    expect(createVMIncompatibilityReasons(self)).toEqual([])
    expect(createVMIncompatibilityReasons(peer)).toEqual(['Device is unreachable'])
    expect(templateIncompatibilityReasons(peer, template())).toEqual(['Device is unreachable'])
  })

  test('PAS-33 arch fields disable a Device that cannot run the guest', () => {
    const x86 = device({
      hostId: 'box',
      role: 'member',
      platform: { os: 'Linux', arch: 'x86_64' },
    })
    expect(createVMIncompatibilityReasons(x86, { guestArch: 'arm64', capabilities: x86Caps })).toEqual([
      'Architecture (arm64) is not compatible with this Device (x86_64).',
    ])
    expect(templateIncompatibilityReasons(x86, template({ architectures: ['arm64'] }), { capabilities: x86Caps })).toContain(
      'Architecture (arm64) is not compatible with this Device (x86_64).',
    )
  })

  test('Windows follows advertised guestTypes, not an arm64-only host check', () => {
    const x86 = device({
      hostId: 'box',
      role: 'member',
      platform: { os: 'Linux', arch: 'x86_64' },
    })
    expect(createVMIncompatibilityReasons(x86, { osType: 'windows', capabilities: x86Caps })).toEqual([])
    expect(
      createVMIncompatibilityReasons(x86, {
        osType: 'windows',
        capabilities: {
          ...x86Caps,
          guestTypes: [
            { id: 'linux-amd64', arch: 'x86_64', machine: 'q35', osFamily: 'linux', qemuBinary: 'qemu-system-x86_64' },
            { id: 'windows-amd64', arch: 'x86_64', machine: 'q35', osFamily: 'windows', qemuBinary: 'qemu-system-x86_64' },
          ],
        },
      }),
    ).toEqual([])
    expect(
      createVMIncompatibilityReasons(x86, {
        osType: 'windows',
        capabilities: {
          ...x86Caps,
          guestTypes: [
            { id: 'linux-amd64', arch: 'x86_64', machine: 'q35', osFamily: 'linux', qemuBinary: 'qemu-system-x86_64' },
          ],
        },
      }),
    ).toEqual(['Windows guests are not available on this Device architecture.'])
    expect(guestTypesSupportWindows([
      { id: 'windows-amd64', arch: 'x86_64', osFamily: 'windows' },
    ], 'x86_64')).toBe(true)
    expect(guestTypesSupportWindows([
      { id: 'windows-arm64', arch: 'arm64', osFamily: 'windows' },
    ], 'x86_64')).toBe(false)
  })

  test('bridged templates fail closed when capabilities are the PAS-37 defaults', () => {
    const peer = device({ hostId: 'studio', role: 'member' })
    expect(
      templateIncompatibilityReasons(peer, template({ networkMode: 'bridged' }), {
        capabilities: defaultCapabilities,
      }),
    ).toContain('Bridged networking is not available on this Device.')
  })

  test('required features and bridged templates use picked-Device capabilities', () => {
    const peer = device({ hostId: 'studio', role: 'member' })
    expect(
      templateIncompatibilityReasons(
        peer,
        template({ requiredFeatures: ['usbPassthrough'], networkMode: 'bridged' }),
        { capabilities: x86Caps },
      ),
    ).toContain('Bridged networking is not available on this Device.')
    expect(
      createVMIncompatibilityReasons(peer, {
        requiredFeatures: ['usbPassthrough'],
        capabilities: { ...armCaps, supportsUSBPassthrough: false },
      }),
    ).toEqual(['Missing usbPassthrough'])
  })

  test('missing Library copy is a placement reason for templates and Create VM', () => {
    const peer = device({ hostId: 'studio', role: 'member' })
    expect(templateIncompatibilityReasons(peer, template(), { hasTemplate: false })).toEqual([
      "Not in this Device's Library",
    ])
    expect(createVMIncompatibilityReasons(peer, { hasImage: false })).toEqual([
      "Not in this Device's Library",
    ])
    const option = toPickOption(peer, [])
    expect(option.compatible).toBe(true)
    expect(option.label).toBe('studio')
    const recommended = toPickOption(peer, [], {
      recommended: true,
      recommendReasons: ['2048 MB free memory, 10% CPU load.'],
    })
    expect(recommended.recommended).toBe(true)
    expect(recommended.recommendReasons).toEqual(['2048 MB free memory, 10% CPU load.'])
  })
})
