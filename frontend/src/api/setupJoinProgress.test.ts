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

  test('SetupView persists join progress and resumes join-ready after refresh', () => {
    const setup = readFileSync(join(here, '../views/SetupView.vue'), 'utf8')
    expect(setup).toContain('loadSetupJoinProgress')
    expect(setup).toContain('saveSetupJoinProgress')
    expect(setup).toContain('clearSetupJoinProgress')
    expect(setup).toMatch(/joinResult\.value = saved/)
    expect(setup).toMatch(/saveSetupJoinProgress\(joinResult\.value\)/)
    expect(setup).toMatch(/clearSetupJoinProgress\(\)/)
  })
})
