import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const helper = readFileSync(
  join(here, '../../../.agents/skills/verify-barkvisor/helpers/bridge-setup-flow.mjs'),
  'utf8',
)

describe('bridge-setup-flow helper (#418)', () => {
  test('opens Bridge setup and asserts DHCP/static Apply/Revert without Setup/Start/Stop', () => {
    expect(helper).toContain('/networks')
    expect(helper).toContain('Bridge setup')
    expect(helper).toContain('Device address')
    expect(helper).toContain('DHCP')
    expect(helper).toContain('static')
    expect(helper).toContain('Apply')
    expect(helper).toContain('Revert')
    expect(helper).toContain("['Setup', 'Start', 'Stop']")
    expect(helper).toContain('--check')
    expect(helper).toContain('addressing')
    expect(helper).toContain("action: 'check'")
    expect(helper).toContain('bridge-setup.png')
  })
})
