import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { applyPortForwardBind } from './portForwardBind'

const editorSource = readFileSync(
  resolve(import.meta.dir, '../components/PortForwardEditor.vue'),
  'utf8',
)

describe('applyPortForwardBind', () => {
  test('a typed bind is trimmed and stored', () => {
    const rule = { protocol: 'tcp' as const, hostPort: 2222, guestPort: 22 }
    expect(applyPortForwardBind(rule, 'host', ' 127.0.0.1 ')).toEqual({
      protocol: 'tcp',
      hostPort: 2222,
      guestPort: 22,
      host: '127.0.0.1',
    })
  })

  test('an emptied box drops the key instead of sending an empty bind', () => {
    // The API answers 400 "Published port is missing a bind address" for "".
    const rule = { protocol: 'tcp' as const, hostPort: 2222, guestPort: 22, host: '127.0.0.1' }
    const next = applyPortForwardBind(rule, 'host', '')
    expect('host' in next).toBe(false)
    expect(next).toEqual({ protocol: 'tcp', hostPort: 2222, guestPort: 22 })
  })

  test('whitespace alone counts as empty, never as a bind', () => {
    const rule = { protocol: 'udp' as const, hostPort: 53, guestPort: 53, host: '127.0.0.1' }
    expect('host' in applyPortForwardBind(rule, 'host', '   ')).toBe(false)
  })

  test('the compose spelling writes hostIP, leaving host alone', () => {
    const rule = { protocol: 'tcp' as const, hostPort: 8080, guestPort: 80 }
    expect(applyPortForwardBind(rule, 'hostIP', '10.0.0.5')).toEqual({
      protocol: 'tcp',
      hostPort: 8080,
      guestPort: 80,
      hostIP: '10.0.0.5',
    })
  })

  test('clearing does not disturb the rest of the rule', () => {
    const rule = {
      protocol: 'tcp' as const,
      hostPort: 2222,
      guestPort: 22,
      host: '127.0.0.1',
      httpPath: '/ssh',
    }
    expect(applyPortForwardBind(rule, 'host', '')).toEqual({
      protocol: 'tcp',
      hostPort: 2222,
      guestPort: 22,
      httpPath: '/ssh',
    })
  })
})

describe('PortForwardEditor bind input', () => {
  test('a new rule carries no bind, so it publishes on every IPv4 interface', () => {
    expect(editorSource).toContain(
      "model.value = [...model.value, { protocol: 'tcp', hostPort: 0, guestPort: 0 }]",
    )
  })

  test('the input explains the empty default', () => {
    expect(editorSource).toContain('placeholder="Every interface"')
    expect(editorSource).toContain('every IPv4 interface of the Device')
  })

  test('the compose app editor edits the address the compose document stores', () => {
    const detailSource = readFileSync(
      resolve(import.meta.dir, '../views/VMDetailView.vue'),
      'utf8',
    )
    expect(detailSource).toContain('<PortForwardEditor v-model="appPortsDraft" bind-field="hostIP" />')
  })
})
