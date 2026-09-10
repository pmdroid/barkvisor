import { describe, expect, it } from 'vitest'
import { appCatalogSource, appIngressMode, isSecretEnvKey } from './appDetail'
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

describe('isSecretEnvKey', () => {
  it('hides password keys', () => {
    expect(isSecretEnvKey('PLEX_CLAIM')).toBe(true)
    expect(isSecretEnvKey('TZ')).toBe(false)
  })
})
