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

  test('macos-guide and linux-guide keep mutation action keys internal', () => {
    expect(bridgeGuideActionKeys('macos-guide')).toEqual([])
    expect(bridgeGuideActionKeys('linux-guide')).toEqual([])
    for (const action of BRIDGE_MUTATION_ACTION_KEYS) {
      expect(bridgeGuideActionKeys('linux-guide')).not.toContain(action)
      expect(bridgeGuideActionKeys('macos-guide')).not.toContain(action)
    }
  })

  test('NetworkView renders interface-first tabs with Apply on interface drawer', () => {
    const src = readFileSync(join(here, '../views/NetworkView.vue'), 'utf8')
    expect(src).toContain('bridgeManagementMode')
    expect(src).toContain('canCreateHostBridge')
    expect(src).toContain('hostBridgeDevices')
    expect(src).toContain('canGuideCreateBridge')
    expect(src).toContain('createBridgeDeviceOptions')
    expect(src).toContain('HostInterfaceAddressList')
    expect(src).toContain("activeTab = 'interfaces'")
    expect(src).toContain('Host interfaces')
    expect(src).toContain('VM networks')
    expect(src).not.toContain('Bridge setup')
    expect(src).toContain('canApplySelectedInterface')
    expect(src).toContain('canDeleteSelectedInterface')
    expect(src).toContain('runInterfaceHostBridge')
    expect(src).toContain('data.needsConfirm || data.success')
    expect(src).toContain('applySelectedInterface')
    expect(src).not.toContain('revertSelectedInterface')
    expect(src).not.toContain('recheckSelectedInterface')
    expect(src).not.toContain('createBridgeVmNetwork')
    expect(src).not.toContain('Create VM network')
    expect(src).not.toContain('GuestCommandAccordion')
    expect(src).not.toContain('Advanced CLI')
    expect(src).not.toContain('macosSocketVmnetSetupGroups')
    expect(src).not.toContain('linuxBridgeSetupGroups')
    expect(src).toContain('interfaceOwnsAddressApply')
    expect(src).toContain('deleteSelectedInterface')
    expect(src).toContain('selectedInterfaceShowsDelete')
    expect(src).toContain('action: \'delete\'')
    expect(src).toContain('interfaceShowsDelete')
    expect(src).toContain('existingBridgeForInterfaceApply')
    expect(src).toContain('gateway: createBridgeGateway.value')
    expect(src).not.toContain(':gateway="createBridgeGateway"')
    expect(src).not.toContain("selectedInterfaceRole.value === 'bridge' ? nic : undefined")
    expect(src).toContain('addressApplyTargets')
    expect(src).toContain('overlayBridgeAddresses')
    expect(src).not.toContain('interfaceBridgeRoleDetail')
    expect(src).toContain('openBridgeSetupForPending')
    expect(src).toContain('bridgeSetupInterfaceKey')
    expect(src).toContain('applyButtonLabel')
    expect(src).not.toContain('>Revert</AppButton>')
    expect(src).toContain('>Delete</AppButton>')
    expect(src).not.toContain('>Setup</AppButton>')
    expect(src).not.toContain('>Start</AppButton>')
    expect(src).not.toContain('>Stop</AppButton>')
    expect(src).not.toContain('removeBridge')
    expect(src).not.toContain('setupBridgeInline')
    expect(src).not.toContain('canManageBridges')
    expect(src).not.toContain('Pick the uplink interface')
    expect(src).not.toContain('BarkVisor creates the bridge')
    expect(src).not.toContain('bridgeHostAddressing')
    expect(src).not.toContain('runHostBridge')
    expect(src).not.toContain('recheckPending')
    expect(src).not.toContain('Device address on')
    expect(src).toContain('hostBridgeSetupPending')
    expect(src).toContain('interfaceAddressColumn')
    expect(src).toContain('pendingCommitBridgeName')
    expect(src).toContain('pendingCommitMatchesInterface')
    expect(src).toContain('showPendingCommitModal')
    expect(src).toContain('Keep network changes')
    expect(src).toContain('Apply these network changes?')
    expect(src).toContain(':details="linuxApplyResult?.changes ?? []"')
    expect(src).toContain(':commands="linuxApplyResult?.commands ?? []"')
    expect(src).not.toContain('linuxApplyResult && activeTab')
    expect(src).not.toContain('showPendingCommitBanner')
    expect(src).toContain('bridge: existingBridge ?? undefined')
    expect(src).not.toContain('bridge: existingBridge ?? (targets.bridge || undefined)')
  })

  test('NetworkView VM tab distinguishes Workload network from Device address (#432)', () => {
    const src = readFileSync(join(here, '../views/NetworkView.vue'), 'utf8')
    expect(src).toContain('Workload networks are logical')
    expect(src).toContain('Device addresses')
    expect(src).toContain('Workload network')
    expect(src).toContain('Host bridge interface')
    expect(src).toContain('deleteNetwork(selectedRow)')
    expect(src).toContain("activeTab === 'vm'")
    expect(src).not.toContain('HOST_BRIDGE_SUGGESTED')
    expect(src).not.toContain('bridge-custom')
  })
})
