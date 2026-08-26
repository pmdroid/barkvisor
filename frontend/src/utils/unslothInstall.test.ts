import { describe, expect, test } from 'bun:test'
import {
  UNSLOTH_INSTALL_COMMAND,
  UNSLOTH_INSTALL_HINT,
  UNSLOTH_STAGE_DIR,
  UNSLOTH_STAGE_HINT,
  unslothInstallSteps,
} from './unslothInstall'

describe('unsloth install copy', () => {
  test('hint matches UnslothDetect.installHint', () => {
    expect(UNSLOTH_INSTALL_HINT).toBe(
      'Install Unsloth with: curl -fsSL https://unsloth.ai/install.sh | sh',
    )
    expect(UNSLOTH_INSTALL_COMMAND).toBe('curl -fsSL https://unsloth.ai/install.sh | sh')
  })

  test('stage copy points at unsloth/models under the data dir', () => {
    expect(UNSLOTH_STAGE_DIR).toBe('unsloth/models')
    expect(UNSLOTH_STAGE_HINT).toContain('GGUF')
    expect(UNSLOTH_STAGE_HINT).toContain(UNSLOTH_STAGE_DIR)
  })

  test('install steps include the command only when not installed', () => {
    const fresh = unslothInstallSteps(false)
    expect(fresh.length).toBe(2)
    expect(fresh[0]?.command).toBe(UNSLOTH_INSTALL_COMMAND)
    expect(fresh[1]?.command).toBeUndefined()

    const staged = unslothInstallSteps(true)
    expect(staged.length).toBe(1)
    expect(staged[0]?.title).toBe(UNSLOTH_STAGE_HINT)
    expect(staged[0]?.command).toBeUndefined()
  })
})
