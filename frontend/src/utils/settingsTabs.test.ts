import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  DEFAULT_SETTINGS_TAB,
  isPairingTab,
  SETTINGS_TABS,
  settingsTabFromQuery,
  shouldRunPairingTick,
  SSH_KEYS_SETTINGS_HREF,
  REPOSITORIES_SETTINGS_HREF,
} from './settingsTabs'

const here = dirname(fileURLToPath(import.meta.url))

describe('settings tab query', () => {
  test('maps query tab values including pairing', () => {
    expect(SETTINGS_TABS).toContain('pairing')
    expect(SETTINGS_TABS).toContain('home')
    expect(SETTINGS_TABS).toContain('disks')
    expect(SETTINGS_TABS).toContain('repositories')
    expect(DEFAULT_SETTINGS_TAB).toBe('apikeys')

    expect(settingsTabFromQuery('pairing')).toBe('pairing')
    expect(settingsTabFromQuery('home')).toBe('home')
    expect(settingsTabFromQuery('library')).toBe('library')
    expect(settingsTabFromQuery('repositories')).toBe('repositories')
    expect(settingsTabFromQuery('disks')).toBe('disks')
    expect(settingsTabFromQuery('apikeys')).toBe('apikeys')
    expect(settingsTabFromQuery('sshkeys')).toBe('sshkeys')
    expect(SSH_KEYS_SETTINGS_HREF).toBe('/settings?tab=sshkeys')
    expect(REPOSITORIES_SETTINGS_HREF).toBe('/settings?tab=repositories')
    expect(settingsTabFromQuery('passkeys')).toBe('passkeys')
    expect(settingsTabFromQuery('audit')).toBe('audit')
    expect(settingsTabFromQuery('updates')).toBe('updates')
    expect(SETTINGS_TABS).toContain('updates')

    expect(settingsTabFromQuery({ tab: 'pairing' })).toBe('pairing')
    expect(settingsTabFromQuery({ tab: 'home' })).toBe('home')
    expect(settingsTabFromQuery({ tab: ['pairing'] })).toBe('pairing')
    expect(settingsTabFromQuery({ tab: ['home', 'pairing'] })).toBe('home')

    expect(settingsTabFromQuery(undefined)).toBeUndefined()
    expect(settingsTabFromQuery(null)).toBeUndefined()
    expect(settingsTabFromQuery('')).toBeUndefined()
    expect(settingsTabFromQuery('unknown')).toBeUndefined()
    expect(settingsTabFromQuery({ tab: 'bogus' })).toBeUndefined()
    expect(settingsTabFromQuery({})).toBeUndefined()
    expect(settingsTabFromQuery({ tab: ['nope'] })).toBeUndefined()

    expect(isPairingTab('pairing')).toBe(true)
    expect(isPairingTab(settingsTabFromQuery('pairing'))).toBe(true)
    expect(isPairingTab(settingsTabFromQuery({ tab: 'pairing' }))).toBe(true)
    expect(isPairingTab('home')).toBe(false)
    expect(isPairingTab(settingsTabFromQuery('home'))).toBe(false)
    expect(isPairingTab(settingsTabFromQuery('apikeys'))).toBe(false)
    expect(isPairingTab(undefined)).toBe(false)
    expect(isPairingTab(null)).toBe(false)
  })

  test('pairing tick runs only on the pairing tab while an offer is showing', () => {
    expect(shouldRunPairingTick('pairing', true)).toBe(true)
    expect(shouldRunPairingTick('pairing', false)).toBe(false)
    expect(shouldRunPairingTick('home', true)).toBe(false)
    expect(shouldRunPairingTick('apikeys', true)).toBe(false)
    expect(shouldRunPairingTick('library', false)).toBe(false)
    expect(shouldRunPairingTick(undefined, true)).toBe(false)

    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain('shouldRunPairingTick')
    expect(settings).toContain('watch([tab, pairingOffer, loginOffer]')
    expect(settings).toContain('stopPairingTick')
  })

  test('Settings wires pairing as its own tab from ?tab=', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    expect(settings).toContain('settingsTabFromQuery')
    expect(settings).toContain('isPairingTab')
    expect(settings).toContain('openPairingTab')
    expect(settings).toContain('v-if="isPairingTab(tab)"')
    expect(settings).toContain("tab === 'home'")
    expect(settings).toContain('Phone sign-in')
    expect(settings).not.toContain('PairingQr')
    expect(settings).toContain('issueLoginOffer')
    expect(settings).toContain('Re-pair this {{ DEVICE_LABEL }}')
    expect(settings).toContain('Device URL')
    expect(settings).toContain('openPairingTab')
    const homeStart = settings.indexOf('v-if="tab === \'home\'"')
    const pairingStart = settings.indexOf('v-if="isPairingTab(tab)"')
    const homeBlock = settings.slice(homeStart, pairingStart > homeStart ? pairingStart : undefined)
    expect(homeStart).toBeGreaterThan(-1)
    expect(pairingStart).toBeGreaterThan(-1)
    expect(homeBlock).toContain('Device URL')
    expect(homeBlock).toContain('Advertised hosts')
    expect(homeBlock).toContain('openPairingTab')
    expect(homeBlock).not.toContain('What you can do on this Home')
    expect(homeBlock).not.toContain('roleTag')
    expect(homeBlock).not.toContain('roleNote')
    expect(settings).not.toContain('roleTag')
    expect(settings).not.toContain('useAuthStore')
    expect(homeBlock).not.toContain('Device name')
    expect(homeBlock).not.toContain('deviceNameDraft')
    expect(homeBlock).not.toContain('Library depot')
    expect(homeBlock).not.toContain('Catalog Download')
    expect(homeBlock).not.toContain('PairingQr')
    expect(homeBlock).not.toContain('Phone sign-in')
    expect(homeBlock).not.toContain('Re-pair this')
    expect(homeBlock).not.toContain('Show sign-in QR')
    const pairingBlock = settings.slice(pairingStart)
    expect(pairingBlock).not.toContain('PairingQr')
    expect(pairingBlock).toContain('Phone sign-in')
    expect(pairingBlock).toContain('Re-pair this {{ DEVICE_LABEL }}')

    const devices = readFileSync(join(here, '../views/DevicesView.vue'), 'utf8')
    expect(devices).toContain('/settings?tab=pairing')
    expect(devices).not.toContain('/settings?tab=home')
  })

  test('Catalog Download lives on Settings Library, not Home', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    const libraryStart = settings.indexOf('v-if="tab === \'library\'"')
    const reposStart = settings.indexOf('v-if="tab === \'repositories\'"')
    const disksStart = settings.indexOf('v-if="tab === \'disks\'"')
    expect(libraryStart).toBeGreaterThan(-1)
    expect(reposStart).toBeGreaterThan(libraryStart)
    expect(disksStart).toBeGreaterThan(reposStart)
    const libraryBlock = settings.slice(libraryStart, reposStart)
    expect(libraryBlock).toContain('Catalog Download')
    expect(libraryBlock).not.toContain('Save Library depot')
    expect(libraryBlock).not.toContain('Library depot')
    expect(libraryBlock).toContain('Library path')
    expect(libraryBlock).toContain('LibraryFolderForm')
    expect(libraryBlock).toContain('librarySettings.isDefault')
    expect(libraryBlock).toContain('lastSyncedAt')
  })

  test('Repository URLs and sync live on Settings Repositories, not a catalog page', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    const app = readFileSync(join(here, '../App.vue'), 'utf8')
    const router = readFileSync(join(here, '../router/index.ts'), 'utf8')
    expect(settings).toContain('openRepositoriesTab')
    expect(settings).toContain("tab === 'repositories'")
    expect(settings).toContain('RepositorySettings')
    const repos = readFileSync(join(here, '../components/RepositorySettings.vue'), 'utf8')
    expect(repos).toContain('Catalog URLs each Device in this Home syncs')
    expect(repos).not.toContain('Catalog URLs this Home syncs')
    expect(repos).toContain('deviceSyncs')
    expect(repos).toContain('fetchHealth')
    expect(app).not.toContain('/registry')
    expect(app).not.toContain('nav-label">Repositories')
    expect(router).toContain('REPOSITORIES_SETTINGS_HREF')
    expect(router).not.toContain('RegistryView')
  })

  test('Create VM SSH picker is on Configure and opens Settings sshkeys in a new tab', () => {
    const configure = readFileSync(
      join(here, '../components/create-vm/CreateVMConfigureStep.vue'),
      'utf8',
    )
    const ssh = configure.indexOf('v-if="showSshKey"')
    const adv = configure.indexOf('<details class="mag-adv">')
    expect(ssh).toBeGreaterThan(-1)
    expect(adv).toBeGreaterThan(-1)
    expect(ssh).toBeLessThan(adv)
    expect(configure).toContain('SSH_KEYS_SETTINGS_HREF')
    expect(configure).toContain('target="_blank"')
    expect(configure).toContain('This VM needs an SSH key for first login')
  })

  test('Default VM disk directory lives on Settings Disks, not the Disks list', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    const disks = readFileSync(join(here, '../views/DiskView.vue'), 'utf8')
    expect(settings).toContain("tab === 'disks'")
    expect(settings).toContain('openDisksTab')
    expect(settings).toContain('Default VM disk directory')
    expect(settings).toContain('deviceDiskSettingsPath')
    expect(settings).toContain('diskSettingsDevice')
    expect(settings).toContain('diskDeviceOptions')
    expect(settings).toContain(':device="diskSettingsDevice"')
    expect(disks).not.toContain('Default VM disk directory')
    expect(disks).toContain('/settings?tab=disks')
    expect(disks).toContain('Create Disk')
    expect(disks).not.toContain('<label>Location</label>')
    expect(disks).not.toContain('showCreatePicker')
  })

  test('Updates tab is Settings → Updates and polls /api/health after apply', () => {
    const settings = readFileSync(join(here, '../views/SettingsView.vue'), 'utf8')
    const tab = readFileSync(join(here, '../components/SettingsUpdatesTab.vue'), 'utf8')
    expect(SETTINGS_TABS).toContain('updates')
    expect(settings).toContain("tab === 'updates'")
    expect(settings).toContain('SettingsUpdatesTab')
    expect(settings).toContain('>Updates</button>')
    expect(tab).toContain('/system/updates/check')
    expect(tab).toContain('/system/updates/install')
    expect(tab).toContain('pollUntilHealthy')
    expect(tab).toContain("api.get('/health')")
    expect(tab).not.toContain('brew upgrade')
    expect(tab).not.toContain('HelperXPC')
    expect(tab).not.toContain('cluster')
    expect(tab).not.toContain('node')
  })
})
