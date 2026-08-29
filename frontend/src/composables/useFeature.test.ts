import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createPinia, setActivePinia } from 'pinia'
import { useCapabilitiesStore } from '../stores/capabilities'
import {
  BRIDGE_MUTATION_ACTION_KEYS,
  bridgeGuideActionKeys,
  bridgeManagementMode,
  networksUsableOnHost,
  useFeature,
} from './useFeature'

const here = dirname(fileURLToPath(import.meta.url))

const originalFetch = globalThis.fetch

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

const linuxCaps = {
  platform: 'Linux',
  supportsBridgedNetworking: false,
  supportsManagedBridgeDaemon: false,
  supportsUSBPassthrough: true,
  supportsInAppUpdate: false,
  accelerator: 'kvm',
  hostArch: 'x86_64',
  hostCpuCount: 8,
  guestTypes: [],
  details: [
    {
      code: 'bridgedNetworking',
      supported: false,
      reasonCode: 'helper_missing',
      remediation: 'Install qemu-bridge-helper and a host bridge.',
    },
    { code: 'usbPassthrough', supported: true },
    {
      code: 'inAppUpdate',
      supported: false,
      reasonCode: 'linux_pkg_update',
      remediation: 'Use the package manager.',
    },
    { code: 'kvmDevice', supported: true },
  ],
  runnableArches: ['x86_64'],
}

describe('useFeature (PAS-38)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test('is fail-closed before a capabilities document arrives', () => {
    const usb = useFeature('usbPassthrough')
    const bridged = useFeature('bridgedNetworking')
    expect(usb.available).toBe(false)
    expect(usb.loaded).toBe(false)
    expect(usb.explanation).toBeUndefined()
    expect(bridged.available).toBe(false)
  })

  test('reflects current-host flags and server remediation after load', async () => {
    globalThis.fetch = mock().mockResolvedValue(jsonResponse(linuxCaps)) as unknown as typeof fetch
    const store = useCapabilitiesStore()
    await store.fetchCapabilities()

    const usb = useFeature('usbPassthrough')
    const bridged = useFeature('bridgedNetworking')
    const updates = useFeature('inAppUpdate')
    const kvm = useFeature('kvmDevice')

    expect(store.isSupported('usbPassthrough')).toBe(true)
    expect(store.isSupported('bridgedNetworking')).toBe(false)
    expect(store.isSupported('unknownFeature')).toBe(false)
    expect(usb.available).toBe(true)
    expect(usb.explanation).toBeUndefined()
    expect(bridged.available).toBe(false)
    expect(bridged.explanation).toBe('Install qemu-bridge-helper and a host bridge.')
    expect(updates.available).toBe(false)
    expect(updates.explanation).toBe('Use the package manager.')
    expect(kvm.available).toBe(true)
    expect(usb.loaded).toBe(true)
  })

  test('does not invent remediation when details are missing', async () => {
    const body = { ...linuxCaps, details: undefined, supportsBridgedNetworking: false }
    globalThis.fetch = mock().mockResolvedValue(jsonResponse(body)) as unknown as typeof fetch
    await useCapabilitiesStore().fetchCapabilities()

    const bridged = useFeature('bridgedNetworking')
    expect(bridged.available).toBe(false)
    expect(bridged.explanation).toBeUndefined()
  })

  test('networksUsableOnHost drops bridged rows when the host cannot bridge', () => {
    const nets = [
      { id: 'n1', mode: 'nat' },
      { id: 'n2', mode: 'bridged' },
    ]
    expect(networksUsableOnHost(nets, true).map((n) => n.id)).toEqual(['n1', 'n2'])
    expect(networksUsableOnHost(nets, false).map((n) => n.id)).toEqual(['n1'])
  })

  test('bridgeManagementMode is linux-guide, macos-guide, or hidden', () => {
    expect(bridgeManagementMode({
      platform: 'Linux',
      supportsHostBridgeManagement: true,
    })).toBe('linux-guide')
    expect(bridgeManagementMode({ platform: 'linux' })).toBe('linux-guide')
    expect(bridgeManagementMode({
      platform: 'macOS',
      supportsManagedBridgeDaemon: false,
    })).toBe('macos-guide')
    expect(bridgeManagementMode({
      platform: 'darwin',
      supportsManagedBridgeDaemon: true,
    })).toBe('macos-guide')
    expect(bridgeManagementMode({ supportsManagedBridgeDaemon: true })).toBe('macos-guide')
    expect(bridgeManagementMode({})).toBe('hidden')
    expect(bridgeManagementMode({ platform: '', supportsHostBridgeManagement: false })).toBe('hidden')
  })

  test('macos-guide has Setup/Start/Stop, Linux has none, Remove stays gone', () => {
    expect(bridgeGuideActionKeys('macos-guide')).toEqual(['setup', 'start', 'stop'])
    expect(bridgeGuideActionKeys('linux-guide')).toEqual([])
    expect(bridgeGuideActionKeys('hidden')).toEqual([])
    expect(bridgeGuideActionKeys('macos-guide')).not.toContain('remove')
    for (const action of BRIDGE_MUTATION_ACTION_KEYS) {
      expect(bridgeGuideActionKeys('linux-guide')).not.toContain(action)
    }
  })

  test('NetworkView renders Linux apply/revert and macOS Setup/Start/Stop', () => {
    const src = readFileSync(join(here, '../views/NetworkView.vue'), 'utf8')
    expect(src).toContain('bridgeManagementMode')
    expect(src).toContain('macosSocketVmnetSetupGroups')
    expect(src).toContain('linuxBridgeSetupGroups')
    expect(src).toContain('GuestCommandAccordion')
    expect(src).toContain('Bridge setup')
    expect(src).toContain('applyLinuxBridge')
    expect(src).toContain('revertLinuxBridge')
    expect(src).toContain('linuxBridgeCanApply')
    expect(src).toContain('macosSocketVmnetCanManage')
    expect(src).toContain('runMacosSocket')
    expect(src).toContain("runMacosSocket('setup')")
    expect(src).toContain("runMacosSocket('start')")
    expect(src).toContain("runMacosSocket('stop')")
    expect(src).toContain('>Setup</AppButton>')
    expect(src).toContain('>Start</AppButton>')
    expect(src).toContain('>Stop</AppButton>')
    expect(src).not.toContain('removeBridge')
    expect(src).not.toContain('>Remove</AppButton>')
    expect(src).not.toContain('setupBridgeInline')
    expect(src).not.toContain('canManageBridges')
    expect(src).not.toContain('Pick the uplink interface')
    expect(src).not.toContain('BarkVisor creates the bridge')
    expect(src).toContain('recheckPending')
    expect(src).toContain('hostBridgeSetupPending')
  })
})
