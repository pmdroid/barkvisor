import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { useCapabilitiesStore } from '../stores/capabilities'
import { networksUsableOnHost, useFeature } from './useFeature'

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
})
