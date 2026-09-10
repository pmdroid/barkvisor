import { describe, expect, it } from 'vitest'
import {
  appCatalogSource,
  appIngressMode,
  appIngressState,
  appToolbarSub,
  buildEnvSavePayload,
  composeProjectName,
  formatCreatedAgo,
  isSecretEnvKey,
  parseRestartPolicy,
} from './appDetail'
import type { VM } from '../api/types'

function vm(partial: Partial<VM>): VM {
  return {
    id: '1',
    name: 'plex',
    vmType: 'linux-arm64',
    state: 'running',
    cpuCount: 2,
    memoryMB: 2048,
    bootDiskId: null,
    isoId: null,
    isoIds: null,
    networkId: null,
    cloudInitPath: null,
    description: null,
    bootOrder: null,
    displayResolution: null,
    additionalDiskIds: null,
    uefi: false,
    tpmEnabled: false,
    macAddress: null,
    sharedPaths: null,
    ...partial,
  } as VM
}

describe('appCatalogSource', () => {
  it('maps linuxserver label', () => {
    const row = vm({
      spec: {
        apiVersion: 'v1',
        kind: 'Application',
        metadata: { name: 'plex', labels: { 'catalog-source': 'linuxserver' } },
        spec: { resources: { cpu: 1, memoryMb: 512 } },
      },
    })
    expect(appCatalogSource(row)).toBe('LinuxServer')
  })
})

describe('appIngressMode', () => {
  it('marks plex as direct', () => {
    const mode = appIngressMode(vm({ name: 'plex' }))
    expect(mode.direct).toBe(true)
    expect(mode.label).toBe('Direct')
  })
})

describe('appIngressState', () => {
  it('honors spec ingress override', () => {
    const row = vm({
      id: 'jelly-1',
      name: 'jellyfin',
      spec: {
        apiVersion: 'v1',
        kind: 'Application',
        metadata: { name: 'jellyfin' },
        spec: {
          resources: { cpu: 1, memoryMb: 512 },
          ingress: { enabled: true, mode: 'prefix' },
        },
      },
    })
    const state = appIngressState(row)
    expect(state.enabled).toBe(true)
    expect(state.mode).toBe('prefix')
    expect(state.path).toBe('/go/jelly-1/')
  })

  it('can disable ingress', () => {
    const row = vm({
      name: 'wiki',
      ingress: { enabled: false, mode: 'prefix' },
    })
    expect(appIngressState(row).enabled).toBe(false)
    expect(appIngressMode(row).label).toBe('Off')
  })
})

describe('isSecretEnvKey', () => {
  it('hides password keys', () => {
    expect(isSecretEnvKey('PLEX_CLAIM')).toBe(true)
    expect(isSecretEnvKey('TZ')).toBe(false)
  })

  it('matches all secret patterns', () => {
    for (const key of ['DB_PASSWORD', 'API_SECRET', 'AUTH_TOKEN', 'API_KEY', 'PLEX_CLAIM']) {
      expect(isSecretEnvKey(key)).toBe(true)
    }
    expect(isSecretEnvKey('TZ')).toBe(false)
    expect(isSecretEnvKey('PUID')).toBe(false)
  })
})

describe('buildEnvSavePayload', () => {
  it('keeps secret values and applies non-secret edits', () => {
    const payload = buildEnvSavePayload(
      { TZ: 'UTC', PUID: '1000', DB_PASSWORD: 's3cr3t' },
      { TZ: 'Europe/Berlin', PUID: '1000' },
    )
    expect(payload).toEqual({ TZ: 'Europe/Berlin', PUID: '1000', DB_PASSWORD: 's3cr3t' })
  })

  it('drops removed non-secret keys and ignores secret keys in drafts', () => {
    const payload = buildEnvSavePayload(
      { TZ: 'UTC', OLD_VAR: 'x', API_TOKEN: 'abc' },
      { TZ: 'UTC', DB_PASSWORD: 'evil' },
    )
    expect(payload).toEqual({ TZ: 'UTC', API_TOKEN: 'abc' })
    expect(payload).not.toHaveProperty('DB_PASSWORD', 'evil')
    expect(payload).not.toHaveProperty('OLD_VAR')
  })

  it('supports adding non-secret keys', () => {
    const payload = buildEnvSavePayload({ TZ: 'UTC' }, { TZ: 'UTC', NEW_VAR: 'hi' })
    expect(payload).toEqual({ TZ: 'UTC', NEW_VAR: 'hi' })
  })
})

describe('appToolbarSub', () => {
  it('joins tagline, age, and catalog', () => {
    const now = Date.parse('2026-09-10T00:00:00Z')
    const row = vm({
      description: 'Media server',
      createdAt: '2026-08-17T00:00:00Z',
      spec: {
        apiVersion: 'v1',
        kind: 'Application',
        metadata: { name: 'jellyfin', labels: { 'catalog-source': 'bigbear' } },
        spec: { resources: { cpu: 1, memoryMb: 512 } },
      },
    })
    expect(appToolbarSub(row, now)).toBe('Media server · created 24 days ago · via Big Bear catalog')
  })
})

describe('formatCreatedAgo', () => {
  it('uses day units past 24h', () => {
    const now = Date.parse('2026-09-10T00:00:00Z')
    expect(formatCreatedAgo('2026-09-09T00:00:00Z', now)).toBe('1 day ago')
  })
})

describe('parseRestartPolicy', () => {
  it('reads restart from compose yaml', () => {
    expect(parseRestartPolicy('services:\n  x:\n    restart: always\n')).toBe('always')
    expect(parseRestartPolicy('')).toBe('unless-stopped')
  })
})

describe('composeProjectName', () => {
  it('strips dashes from the workload id', () => {
    expect(composeProjectName('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa')).toBe(
      'barkvisor-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    )
  })
})
