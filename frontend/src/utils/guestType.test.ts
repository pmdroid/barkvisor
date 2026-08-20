import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { GUEST_PROFILES, guestProfile, resolveGuestType } from './guestType'

type Case = {
  guestType: string | null
  osFamily: string | null
  arch: string | null
  id: string
  defaultTPMEnabled: boolean
}

const cases = JSON.parse(
  readFileSync(
    join(import.meta.dir, '../../../Tests/BarkVisorTests/Fixtures/guest-type-resolver.cases.json'),
    'utf8',
  ),
) as Case[]

describe('resolveGuestType', () => {
  test('wizard keys match API and spec fixtures', () => {
    for (const row of cases) {
      const id = resolveGuestType({
        guestType: row.guestType,
        osFamily: row.osFamily,
        arch: row.arch,
      })
      expect(id).toBe(row.id)
      expect(guestProfile(id)?.defaultTPMEnabled).toBe(row.defaultTPMEnabled)
    }
  })

  test('keeps windows-amd64 and linux-x86_64 rows', () => {
    const ids = GUEST_PROFILES.map((row) => row.id)
    expect(ids).toEqual([
      'linux-arm64',
      'windows-arm64',
      'linux-amd64',
      'linux-x86_64',
      'windows-amd64',
    ])
    expect(guestProfile('windows-amd64')?.defaultTPMEnabled).toBe(true)
    expect(resolveGuestType({ osFamily: 'linux', arch: 'x86_64' })).toBe('linux-amd64')
    expect(resolveGuestType({ guestType: 'linux-x86_64' })).toBe('linux-x86_64')
  })

  test('rejects arch mismatch on an explicit type', () => {
    expect(() => resolveGuestType({ guestType: 'linux-arm64', arch: 'x86_64' })).toThrow(
      /does not match guestType/,
    )
  })
})
