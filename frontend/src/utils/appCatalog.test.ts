import { describe, expect, test } from 'bun:test'
import type { AppCatalogEntry } from '../api/types'
import {
  appArchLabel,
  appCatalogKey,
  appInstallBlockedReason,
  appSourceLabel,
  appSupportsDeviceArch,
  applicationSpecYaml,
} from './appCatalog'

function app(partial: Partial<AppCatalogEntry> = {}): AppCatalogEntry {
  return {
    id: 'whoami',
    name: 'Whoami',
    category: 'Apps',
    arches: ['arm64', 'amd64'],
    source: 'big-bear-universal',
    compose: 'services:\n  whoami:\n    image: traefik/whoami\n',
    envSchema: [],
    volumes: [],
    ports: [],
    unsupportedReasons: [],
    ui: { scheme: 'http', path: '', proxy: 'direct', basePathEnv: [] },
    ...partial,
  }
}

describe('appCatalog', () => {
  test('maps amd64 to x86_64 for Device arch', () => {
    expect(appSupportsDeviceArch(app(), 'x86_64')).toBe(true)
    expect(appSupportsDeviceArch(app({ arches: ['amd64'] }), 'x86_64')).toBe(true)
    expect(appSupportsDeviceArch(app({ arches: ['amd64'] }), 'arm64')).toBe(false)
    expect(appArchLabel(['amd64', 'arm64'])).toBe('x86_64 · arm64')
  })

  test('unsupported compose blocks install and keeps the card usable as a reason', () => {
    const row = app({ unsupportedReasons: ['privileged'] })
    expect(appInstallBlockedReason(row, 'arm64', true)).toBe('privileged')
  })

  test('arch mismatch is a visible block, not a hide', () => {
    const reason = appInstallBlockedReason(app({ arches: ['amd64'] }), 'arm64', true)
    expect(reason).toContain('arm64')
    expect(reason).toContain('x86_64')
    expect(reason).not.toContain('This Device')
  })

  test('renders an Application spec from the catalog compose', () => {
    const yaml = applicationSpecYaml(app(), 'my-whoami')
    expect(yaml).toContain('kind: Application')
    expect(yaml).toContain('name: "my-whoami"')
    expect(yaml).toContain('traefik/whoami')
  })

  test('quotes Workload names that would break YAML', () => {
    const yaml = applicationSpecYaml(app(), 'foo: bar')
    expect(yaml).toContain('name: "foo: bar"')
    expect(yaml).not.toContain('name: foo: bar')
  })

  test('source chip names LinuxServer and Big Bear', () => {
    expect(appSourceLabel('linuxserver')).toBe('LinuxServer')
    expect(appSourceLabel('big-bear-universal')).toBe('Big Bear')
    expect(appCatalogKey(app({ id: 'jellyfin', source: 'linuxserver' }))).toBe('linuxserver:jellyfin')
  })
})
