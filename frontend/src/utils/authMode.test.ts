import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  authBannerText,
  isFrontDoorBypassed,
  parseAuthMode,
} from './authMode'

const here = dirname(fileURLToPath(import.meta.url))

describe('front-door auth mode', () => {
  test('treats authDisabled as the router bypass flag', () => {
    expect(isFrontDoorBypassed({ authDisabled: true, authMode: 'loopback' })).toBe(true)
    expect(isFrontDoorBypassed({ authDisabled: true, authMode: 'disabled' })).toBe(true)
    expect(isFrontDoorBypassed({ authDisabled: false, authMode: 'secure' })).toBe(false)
    expect(isFrontDoorBypassed({ complete: true })).toBe(false)
    expect(isFrontDoorBypassed(null)).toBe(false)
  })

  test('parses known modes and fails closed to secure', () => {
    expect(parseAuthMode('loopback')).toBe('loopback')
    expect(parseAuthMode('disabled')).toBe('disabled')
    expect(parseAuthMode('secure')).toBe('secure')
    expect(parseAuthMode('nope')).toBe('secure')
    expect(parseAuthMode(undefined)).toBe('secure')
  })

  test('banner copy names the scope', () => {
    expect(authBannerText('loopback')).toContain('this computer only')
    expect(authBannerText('disabled')).toContain('everyone on the network')
    expect(authBannerText('secure')).toBe('')
  })

  test('router and settings consume the helpers', () => {
    const router = readFileSync(join(here, '../router/index.ts'), 'utf8')
    expect(router).toContain('isFrontDoorBypassed')
    expect(router).toContain('authDisabled')
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain('Skip sign-in on this computer')
    expect(settings).toContain('Skip sign-in for my whole network')
    expect(settings).toContain('Require sign-in')
    const app = readFileSync(join(here, '../App.vue'), 'utf8')
    expect(app).toContain('authBannerText')
  })

  test('bypass state comes from the per-request status, not the server mode', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).not.toContain('syncFrontDoorSession')
    expect(settings).not.toContain('v-if="securityMode')
    const router = readFileSync(join(here, '../router/index.ts'), 'utf8')
    expect(router).toContain('export async function refreshFrontDoorStatus')
    const setup = readFileSync(join(here, '../views/SetupView.vue'), 'utf8')
    expect(setup).toContain('refreshFrontDoorStatus')
    expect(setup).not.toContain('applyBypass(')
  })
})
