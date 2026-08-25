import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  OLLAMA_DOWNLOAD_HREF,
  OLLAMA_LINUX_INSTALL_HINT,
  OLLAMA_MAC_INSTALL_COMMAND,
  OLLAMA_MAC_INSTALL_HINT,
  OLLAMA_MAC_START_COMMAND,
  ollamaCatalogInstallHint,
  ollamaInstallDevices,
  ollamaInstallHint,
  ollamaInstallOs,
  ollamaInstallOsLabel,
  ollamaInstallOses,
  ollamaInstallSkipDevice,
  ollamaInstallSteps,
  shouldShowOllamaInstall,
} from './ollamaInstall'

const here = dirname(fileURLToPath(import.meta.url))

describe('ollamaInstallSteps', () => {
  test('mac is Homebrew install then brew services start', () => {
    const steps = ollamaInstallSteps('macos')
    expect(steps).toHaveLength(2)
    expect(steps[0]?.title).toBe(OLLAMA_MAC_INSTALL_HINT)
    expect(steps[0]?.command).toBe(OLLAMA_MAC_INSTALL_COMMAND)
    expect(steps[1]?.command).toBe(OLLAMA_MAC_START_COMMAND)
    expect(steps[0]?.title).toContain('brew install ollama')
    expect(ollamaInstallSteps('macOS').map((step) => step.command)).toEqual([
      'brew install ollama',
      'brew services start ollama',
    ])
  })

  test('linux is distro package plus ollama.com/download', () => {
    const steps = ollamaInstallSteps('linux')
    expect(steps.some((step) => step.href === OLLAMA_DOWNLOAD_HREF)).toBe(true)
    expect(steps[0]?.title).toBe(OLLAMA_LINUX_INSTALL_HINT)
    expect(steps[0]?.title.toLowerCase()).toContain('optional')
    expect(steps[0]?.title).toContain('distro package')
    expect(steps[0]?.title).toContain('https://ollama.com/download')
    expect(ollamaInstallSteps('Linux')[0]?.href).toBe('https://ollama.com/download')
    expect(steps[0]?.command).toBeUndefined()
  })

  test('unknown OS uses mac Homebrew like OllamaDetect', () => {
    expect(ollamaInstallSteps('windows')[0]?.command).toBe('brew install ollama')
    expect(ollamaInstallHint('windows')).toBe(OLLAMA_MAC_INSTALL_HINT)
  })
})

describe('ollama install copy', () => {
  test('hint copy matches OllamaDetect', () => {
    expect(ollamaInstallHint('macos')).toBe('Install Ollama with Homebrew: brew install ollama')
    expect(ollamaInstallHint('linux')).toBe(
      'Ollama is optional. Install the distro package or see https://ollama.com/download',
    )
  })

  test('os from platform or installHint', () => {
    expect(ollamaInstallOs('Linux')).toBe('linux')
    expect(ollamaInstallOs('macOS')).toBe('macos')
    expect(ollamaInstallOs('darwin')).toBe('macos')
    expect(ollamaInstallOs(null, OLLAMA_LINUX_INSTALL_HINT)).toBe('linux')
    expect(ollamaInstallOs(null, OLLAMA_MAC_INSTALL_HINT)).toBe('macos')
    expect(ollamaInstallOsLabel('linux')).toBe('Linux')
    expect(ollamaInstallOsLabel('macos')).toBe('macOS')
  })

  test('catalog hint wins then OS default', () => {
    expect(ollamaCatalogInstallHint([{ installHint: 'brew install ollama' }], 'linux')).toBe(
      'brew install ollama',
    )
    expect(ollamaCatalogInstallHint([{ installHint: '  ' }], 'linux')).toBe(OLLAMA_LINUX_INSTALL_HINT)
    expect(ollamaCatalogInstallHint([], 'macos')).toBe(OLLAMA_MAC_INSTALL_HINT)
  })

  test('oses follow Device hints, then platform, then both', () => {
    expect(ollamaInstallOses({ installHints: [OLLAMA_LINUX_INSTALL_HINT] })).toEqual(['linux'])
    expect(ollamaInstallOses({ installHints: [OLLAMA_MAC_INSTALL_HINT] })).toEqual(['macos'])
    expect(
      ollamaInstallOses({
        installHints: [OLLAMA_MAC_INSTALL_HINT, OLLAMA_LINUX_INSTALL_HINT],
      }),
    ).toEqual(['macos', 'linux'])
    expect(ollamaInstallOses({ platformOs: 'Linux' })).toEqual(['linux'])
    expect(ollamaInstallOses({})).toEqual(['macos', 'linux'])
  })
})

describe('Ollama install UI', () => {
  test('install panel waits for catalog load and hides while loading', () => {
    expect(shouldShowOllamaInstall({ loading: false, catalog: null, anyReachable: false })).toBe(false)
    expect(shouldShowOllamaInstall({ loading: true, catalog: null, anyReachable: false })).toBe(false)
    expect(shouldShowOllamaInstall({ loading: true, catalog: { anyReachable: false }, anyReachable: false })).toBe(
      false,
    )
    expect(shouldShowOllamaInstall({ loading: false, catalog: { anyReachable: false }, anyReachable: false })).toBe(
      true,
    )
    expect(shouldShowOllamaInstall({ loading: false, catalog: { anyReachable: true }, anyReachable: true })).toBe(
      false,
    )
    expect(
      shouldShowOllamaInstall({
        loading: false,
        catalog: { anyReachable: false },
        anyReachable: false,
        devices: [
          { hostId: 'agentbox', displayName: 'AgentBox' },
          { hostId: 'mini', displayName: 'Mac mini' },
        ],
      }),
    ).toBe(false)
    expect(
      shouldShowOllamaInstall({
        loading: false,
        catalog: { anyReachable: false },
        anyReachable: false,
        devices: [
          { hostId: 'agentbox', displayName: 'AgentBox' },
          { hostId: 'desk', displayName: 'Desk' },
        ],
      }),
    ).toBe(true)
  })

  test('AgentBox and Mac mini are not Ollama install targets', () => {
    expect(ollamaInstallSkipDevice('agentbox')).toBe(true)
    expect(ollamaInstallSkipDevice('AgentBox')).toBe(true)
    expect(ollamaInstallSkipDevice('Mac mini')).toBe(true)
    expect(ollamaInstallSkipDevice('macmini')).toBe(true)
    expect(ollamaInstallSkipDevice('mac-mini')).toBe(true)
    expect(ollamaInstallSkipDevice('Desk')).toBe(false)
    expect(
      ollamaInstallDevices([
        { hostId: 'agentbox', displayName: 'AgentBox' },
        { hostId: 'desk', displayName: 'Desk' },
        { hostId: 'mini', displayName: 'Mac mini' },
      ]).map((row) => row.hostId),
    ).toEqual(['desk'])
  })

  test('ModelsView ships a multi-step install panel and Recheck', () => {
    const src = readFileSync(join(here, '../views/ModelsView.vue'), 'utf8')
    expect(src).toContain('ollamaInstallSteps')
    expect(src).toContain('ollamaCatalogInstallHint')
    expect(src).toContain('shouldShowOllamaInstall')
    expect(src).toContain('Recheck')
    expect(src).toContain('recheckOllama')
    expect(src).toContain('showOllamaInstall')
    expect(src).toContain('showOllamaCatalog')
    expect(src).toContain('v-else-if="showOllamaCatalog"')
    expect(src).not.toContain('v-else-if="store.anyReachable"')
    expect(src).toContain('store.fetchCatalog()')
    expect(src).not.toContain(':subtitle="store.devices[0]?.installHint')
    expect(src).not.toContain('location.reload')
    expect(src).toContain('Ollama is not reachable')
    expect(src).toContain('<details class="card howto-collapse"')
    expect(src).not.toContain('<details class="card howto-collapse" open')
    expect(src).toContain('Use this API')
    expect(src).not.toContain('dash-stat-label">GPU')
    expect(src).toContain('ollamaInstallDevices')
  })

  test('App.vue shows Ollama for admin or inference when Ollama is down', () => {
    const src = readFileSync(join(here, '../App.vue'), 'utf8')
    expect(src).toContain('auth.isAdmin || auth.isInference')
    expect(src).not.toContain('auth.isInference || ollama.anyReachable')
    expect(src).toMatch(/v-if="auth\.isAdmin \|\| auth\.isInference"/)
  })

  test('Console ModelsView is a multi-step panel not a one-liner', () => {
    const src = readFileSync(
      join(here, '../../../Apps/BarkVisorConsole/Sources/Views/ModelsView.swift'),
      'utf8',
    )
    expect(src).toContain('OllamaInstall.steps')
    expect(src).toContain('Recheck')
    expect(src).toContain('refreshOllamaCatalog')
    expect(src).toContain('OllamaInstall.canRecheck')
    expect(src).toContain('rechecking = true')
    expect(src).toContain('model.ollamaRefreshing')
    expect(src).not.toContain('description: Text(catalog.devices.first?.installHint')
    expect(src).toContain('DisclosureGroup("Use this API"')
    expect(src).toContain('OllamaInstall.shouldShowInstall')
    expect(src).toContain('OllamaInstall.installDevices')
    expect(src).not.toContain('LabeledContent("GPU"')
    const recheckIdx = src.indexOf('rechecking = true')
    const taskIdx = src.indexOf('await model.refreshOllamaCatalog()')
    expect(recheckIdx).toBeGreaterThan(0)
    expect(taskIdx).toBeGreaterThan(recheckIdx)
  })
})
