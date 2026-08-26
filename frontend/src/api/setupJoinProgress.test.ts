import { afterEach, beforeEach, describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { PairingJoin } from './pairing'
import {
  clearSetupJoinProgress,
  loadSetupJoinProgress,
  parseSetupJoinProgress,
  saveSetupJoinProgress,
  SETUP_JOIN_PROGRESS_KEY,
  shouldResumeJoinReady,
} from './setupJoinProgress'

const here = dirname(fileURLToPath(import.meta.url))

const sample: PairingJoin = {
  peerHostId: 'peer-1',
  peerFingerprint: 'abc',
  issuedFingerprint: 'def',
  agentPort: 7778,
  pinned: true,
  apiVersion: 1,
}

const store = new Map<string, string>()

const memoryStorage: Storage = {
  get length() {
    return store.size
  },
  clear() {
    store.clear()
  },
  getItem(key: string) {
    return store.has(key) ? store.get(key)! : null
  },
  key(index: number) {
    return [...store.keys()][index] ?? null
  },
  removeItem(key: string) {
    store.delete(key)
  },
  setItem(key: string, value: string) {
    store.set(key, value)
  },
}

describe('setup join progress (PAS-51)', () => {
  const previous = (globalThis as { sessionStorage?: Storage }).sessionStorage

  beforeEach(() => {
    store.clear()
    Object.defineProperty(globalThis, 'sessionStorage', {
      configurable: true,
      value: memoryStorage,
    })
  })

  afterEach(() => {
    if (previous === undefined) {
      Reflect.deleteProperty(globalThis, 'sessionStorage')
    } else {
      Object.defineProperty(globalThis, 'sessionStorage', {
        configurable: true,
        value: previous,
      })
    }
  })

  test('round-trips a successful join and clears it', () => {
    expect(loadSetupJoinProgress()).toBeNull()
    saveSetupJoinProgress(sample)
    expect(loadSetupJoinProgress()).toEqual(sample)
    expect(store.get(SETUP_JOIN_PROGRESS_KEY)).toContain('peer-1')
    clearSetupJoinProgress()
    expect(loadSetupJoinProgress()).toBeNull()
  })

  test('rejects corrupt or incomplete snapshots', () => {
    expect(parseSetupJoinProgress('{')).toBeNull()
    expect(parseSetupJoinProgress('[]')).toBeNull()
    expect(parseSetupJoinProgress(JSON.stringify({ ...sample, peerHostId: '' }))).toBeNull()
    expect(parseSetupJoinProgress(JSON.stringify({ ...sample, agentPort: 0 }))).toBeNull()
    expect(parseSetupJoinProgress(JSON.stringify({ ...sample, pinned: 'yes' }))).toBeNull()
    store.set(SETUP_JOIN_PROGRESS_KEY, '{')
    expect(loadSetupJoinProgress()).toBeNull()
  })

  test('resumes join-ready from sessionStorage or completed identity, not a receipt leftover', () => {
    expect(shouldResumeJoinReady({ complete: false }, null)).toBe(false)
    // Receipt-only leftover: server must report joined=false when no admin exists.
    expect(shouldResumeJoinReady({ complete: false, joined: false }, null)).toBe(false)
    expect(shouldResumeJoinReady({ complete: false }, sample)).toBe(true)
    // joined=true means identity landed (admin exists), not a pairing receipt alone.
    expect(shouldResumeJoinReady({ complete: false, joined: true }, null)).toBe(true)
    expect(shouldResumeJoinReady({ complete: true, joined: true }, sample)).toBe(false)
  })

  test('SetupView is create-only; join progress is not wired into the SPA', () => {
    const setup = readFileSync(join(here, '../views/SetupView.vue'), 'utf8')
    expect(setup).not.toContain('loadSetupJoinProgress')
    expect(setup).not.toContain('saveSetupJoinProgress')
    expect(setup).not.toContain('shouldResumeJoinReady')
    expect(setup).not.toContain('resumeJoinReady')
    expect(setup).not.toContain('submitJoin')
    expect(setup).toContain('barkvisor join --code')
  })
})
