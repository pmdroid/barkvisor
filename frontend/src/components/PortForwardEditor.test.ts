import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const source = readFileSync(resolve(import.meta.dir, 'PortForwardEditor.vue'), 'utf8')

describe('PortForwardEditor bind address', () => {
  test('a new rule carries no bind, so it publishes on every IPv4 interface', () => {
    expect(source).toContain("model.value = [...model.value, { protocol: 'tcp', hostPort: 0, guestPort: 0 }]")
  })

  test('an emptied box drops the key instead of sending an empty bind', () => {
    expect(source).toContain('const bind = raw.trim()')
    expect(source).toContain('if (bind) next[props.bindField] = bind')
    expect(source).toContain('else delete next[props.bindField]')
  })

  test('the bind input explains the empty default', () => {
    expect(source).toContain('placeholder="Every interface"')
    expect(source).toContain('every IPv4 interface of the Device')
  })
})
