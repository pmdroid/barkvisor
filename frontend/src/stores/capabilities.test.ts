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
    expect(store.hostArch).toBe('arm64')

    await store.fetchCapabilities()
    expect(store.loaded).toBe(true)
    expect(store.hostArchKnown).toBe(true)
    expect(store.hostArch).toBe('arm64')
    expect(store.guestTypes.map((g) => g.id)).toEqual(['windows-arm64'])
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
    const noArch = { ...arm64Caps, hostArch: undefined }
    const fetchMock = mock().mockResolvedValue(jsonResponse(noArch))
    globalThis.fetch = fetchMock as unknown as typeof fetch

    const store = useCapabilitiesStore()
    await store.fetchCapabilities()
    await store.fetchCapabilities()
    expect(store.loaded).toBe(true)
    expect(store.hostArchKnown).toBe(false)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})
