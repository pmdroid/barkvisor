import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import { useCapabilitiesStore } from './capabilities'

const originalFetch = globalThis.fetch

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

const arm64Caps = {
  platform: 'macOS',
  supportsBridgedNetworking: true,
  supportsManagedBridgeDaemon: true,
  supportsUSBPassthrough: true,
  supportsInAppUpdate: true,
  accelerator: 'hvf',
  hostArch: 'arm64',
  hostCpuCount: 10,
  guestTypes: [{ id: 'windows-arm64', arch: 'arm64', machine: 'virt', osFamily: 'windows', qemuBinary: 'qemu' }],
  details: [
    { code: 'usbPassthrough', supported: true },
    { code: 'kvmDevice', supported: false, reasonCode: 'os_unsupported', remediation: 'HVF host' },
    { code: 'tcgOnly', supported: false },
  ],
  inventorySchemaVersion: 1,
  runnableArches: ['arm64'],
}

describe('fetchCapabilities (PAS-48)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test('retries after a network error so hostArch can still be learned', async () => {
    const fetchMock = mock()
      .mockRejectedValueOnce(new TypeError('Failed to fetch'))
      .mockResolvedValueOnce(jsonResponse(arm64Caps))
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const store = useCapabilitiesStore()
    await store.fetchCapabilities()
    expect(store.loaded).toBe(false)
    expect(store.hostArchKnown).toBe(false)
    expect(store.hostArch).toBe('')
    expect(store.supportsUSBPassthrough).toBe(false)
    expect(store.supportsBridgedNetworking).toBe(false)
    expect(store.supportsManagedBridgeDaemon).toBe(false)
    expect(store.supportsInAppUpdate).toBe(false)
    expect(store.runnableArches).toEqual([])
    expect(store.isArchRunnable('arm64')).toBe(false)

    await store.fetchCapabilities()
    expect(store.loaded).toBe(true)
    expect(store.hostArchKnown).toBe(true)
    expect(store.hostArch).toBe('arm64')
    expect(store.guestTypes.map((g) => g.id)).toEqual(['windows-arm64'])
    expect(store.runnableArches).toEqual(['arm64'])
    expect(store.isArchRunnable('arm64')).toBe(true)
    expect(store.isArchRunnable('x86_64')).toBe(false)
    expect(store.detailFor('kvmDevice')?.reasonCode).toBe('os_unsupported')
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  test('retries after a non-2xx boot response (proxy 502)', async () => {
    const fetchMock = mock()
      .mockResolvedValueOnce(jsonResponse({ error: 'bad gateway' }, 502))
      .mockResolvedValueOnce(jsonResponse({ ...arm64Caps, hostArch: 'x86_64', guestTypes: [] }))
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const store = useCapabilitiesStore()
    await store.fetchCapabilities()
    expect(store.loaded).toBe(false)
    expect(store.hostArchKnown).toBe(false)

    await store.fetchCapabilities()
    expect(store.loaded).toBe(true)
    expect(store.hostArchKnown).toBe(true)
    expect(store.hostArch).toBe('x86_64')
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  test('does not refetch after a successful response', async () => {
    const fetchMock = mock().mockResolvedValue(jsonResponse(arm64Caps))
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const store = useCapabilitiesStore()
    await store.fetchCapabilities()
    await store.fetchCapabilities()
    expect(store.hostArchKnown).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  test('in-flight callers share one request', async () => {
    let resolveFetch: ((value: Response) => void) | undefined
    const fetchMock = mock(
      () =>
        new Promise<Response>((resolve) => {
          resolveFetch = resolve
        }),
    )
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const store = useCapabilitiesStore()
    const a = store.fetchCapabilities()
    const b = store.fetchCapabilities()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    resolveFetch!(jsonResponse(arm64Caps))
    await Promise.all([a, b])
    expect(store.hostArchKnown).toBe(true)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  test('older server without hostArch is a successful load, not a retry loop', async () => {
    const noArch = { ...arm64Caps, hostArch: undefined, runnableArches: undefined }
    const fetchMock = mock().mockResolvedValue(jsonResponse(noArch))
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const store = useCapabilitiesStore()
    await store.fetchCapabilities()
    await store.fetchCapabilities()
    expect(store.loaded).toBe(true)
    expect(store.hostArchKnown).toBe(false)
    expect(store.runnableArches).toEqual([])
    expect(store.isArchRunnable('arm64')).toBe(false)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})

describe('fail-closed capabilities (PAS-37)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    globalThis.fetch = originalFetch
  })

  test('defaults invent no features or runnable arch', () => {
    const store = useCapabilitiesStore()
    expect(store.platform).toBe('')
    expect(store.accelerator).toBe('')
    expect(store.hostArch).toBe('')
    expect(store.hostCpuCount).toBe(1)
    expect(store.supportsBridgedNetworking).toBe(false)
    expect(store.supportsManagedBridgeDaemon).toBe(false)
    expect(store.supportsUSBPassthrough).toBe(false)
    expect(store.supportsInAppUpdate).toBe(false)
    expect(store.guestTypes).toEqual([])
    expect(store.details).toEqual([])
    expect(store.runnableArches).toEqual([])
    expect(store.isArchRunnable('arm64')).toBe(false)
    expect(store.isArchRunnable('x86_64')).toBe(false)
  })

  test('linux tcg payload stores details and host-runnable arch', async () => {
    const linuxTcg = {
      platform: 'Linux',
      supportsBridgedNetworking: true,
      supportsManagedBridgeDaemon: false,
      supportsUSBPassthrough: true,
      supportsInAppUpdate: false,
      accelerator: 'tcg',
      hostArch: 'x86_64',
      hostCpuCount: 4,
      guestTypes: [{ id: 'linux-amd64', arch: 'x86_64', machine: 'q35', osFamily: 'linux', qemuBinary: 'qemu-system-x86_64' }],
      details: [
        { code: 'kvmDevice', supported: false, reasonCode: 'kvm_missing', remediation: 'KVM is not available (/dev/kvm missing).' },
        { code: 'tcgOnly', supported: true, reasonCode: 'kvm_missing', remediation: 'Guests run under TCG.' },
        { code: 'inAppUpdate', supported: false, reasonCode: 'linux_pkg_update', remediation: 'Use the package manager.' },
      ],
      inventorySchemaVersion: 1,
      runnableArches: ['x86_64'],
    }
    globalThis.fetch = mock().mockResolvedValue(jsonResponse(linuxTcg)) as unknown as typeof fetch

    const store = useCapabilitiesStore()
    await store.fetchCapabilities()
    expect(store.platform).toBe('Linux')
    expect(store.accelerator).toBe('tcg')
    expect(store.supportsInAppUpdate).toBe(false)
    expect(store.supportsManagedBridgeDaemon).toBe(false)
    expect(store.runnableArches).toEqual(['x86_64'])
    expect(store.isArchRunnable('amd64')).toBe(true)
    expect(store.isArchRunnable('arm64')).toBe(false)
    expect(store.detailFor('kvmDevice')?.reasonCode).toBe('kvm_missing')
    expect(store.detailFor('tcgOnly')?.supported).toBe(true)
    expect(store.detailFor('inAppUpdate')?.reasonCode).toBe('linux_pkg_update')
  })

  test('older server without runnableArches derives from hostArch only', async () => {
    const legacy = { ...arm64Caps, runnableArches: undefined, details: undefined }
    globalThis.fetch = mock().mockResolvedValue(jsonResponse(legacy)) as unknown as typeof fetch

    const store = useCapabilitiesStore()
    await store.fetchCapabilities()
    expect(store.runnableArches).toEqual(['arm64'])
    expect(store.details).toEqual([])
    expect(store.isArchRunnable('arm64')).toBe(true)
  })
})
