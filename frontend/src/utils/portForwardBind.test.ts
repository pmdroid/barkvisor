import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { applyPortForwardBind, portForwardBind } from './portForwardBind'

const editorSource = readFileSync(
  resolve(import.meta.dir, '../components/PortForwardEditor.vue'),
  'utf8',
)

const loopback = { protocol: 'tcp' as const, hostPort: 2222, guestPort: 22, host: '127.0.0.1' }
const wide = { protocol: 'tcp' as const, hostPort: 8080, guestPort: 80 }

describe('applyPortForwardBind', () => {
  test('a typed bind is trimmed and stored', () => {
    expect(applyPortForwardBind(wide, 'host', ' 127.0.0.1 ', '127.0.0.1')).toEqual({
      protocol: 'tcp',
      hostPort: 8080,
      guestPort: 80,
      host: '127.0.0.1',
    })
  })

  test('clearing a box keeps the bind the rule was opened with', () => {
    // The console saves through the flat VM PATCH, which stores the list
    // verbatim — a missing key means "every IPv4 interface" there, with no
    // inheritance. Clearing must therefore never widen a bind by accident.
    const next = applyPortForwardBind(loopback, 'host', '', '127.0.0.1')
    expect(next.host).toBe('127.0.0.1')
    expect(next).toEqual(loopback)
  })

  test('clearing a box that never had a bind stays on every interface', () => {
    const next = applyPortForwardBind(wide, 'host', '', '')
    expect('host' in next).toBe(false)
  })

  test('widening to every interface takes typing the wildcard', () => {
    expect(applyPortForwardBind(loopback, 'host', '0.0.0.0', '127.0.0.1').host).toBe('0.0.0.0')
  })

  test('whitespace alone clears the box without becoming a bind', () => {
    const next = applyPortForwardBind(loopback, 'host', '   ', '127.0.0.1')
    expect(next.host).toBe('127.0.0.1')
  })

  test('the compose spelling writes hostIP, leaving host alone', () => {
    expect(applyPortForwardBind(wide, 'hostIP', '10.0.0.5')).toEqual({
      protocol: 'tcp',
      hostPort: 8080,
      guestPort: 80,
      hostIP: '10.0.0.5',
    })
  })

  test('a compose bind that was set survives clearing its box', () => {
    const rule = { ...wide, hostIP: '10.0.0.5' }
    expect(applyPortForwardBind(rule, 'hostIP', '', '10.0.0.5').hostIP).toBe('10.0.0.5')
  })

  test('clearing does not disturb the rest of the rule', () => {
    const rule = { ...loopback, httpPath: '/ssh' }
    expect(applyPortForwardBind(rule, 'host', '', '127.0.0.1')).toEqual({
      protocol: 'tcp',
      hostPort: 2222,
      guestPort: 22,
      host: '127.0.0.1',
      httpPath: '/ssh',
    })
  })
})

describe('portForwardBind', () => {
  test('an unset, null, or blank bind reads as every interface', () => {
    expect(portForwardBind(wide, 'host')).toBe('')
    expect(portForwardBind({ ...wide, host: null }, 'host')).toBe('')
    expect(portForwardBind({ ...wide, host: '  ' }, 'host')).toBe('')
  })
})

describe('PortForwardEditor bind input', () => {
  test('a new rule carries no bind, so it publishes on every IPv4 interface', () => {
    expect(editorSource).toContain(
      "model.value = [...model.value, { protocol: 'tcp', hostPort: 0, guestPort: 0 }]",
    )
    expect(editorSource).toContain("openedBinds.push('')")
  })

  test('the editor remembers the bind each rule was opened with', () => {
    expect(editorSource).toContain(
      'const openedBinds = model.value.map((rule) => portForwardBind(rule, props.bindField))',
    )
    expect(editorSource).toContain(
      'applyPortForwardBind(rules[index], props.bindField, raw, openedBinds[index])',
    )
  })

  test('the input says how to widen and what empty means', () => {
    expect(editorSource).toContain('placeholder="Every interface"')
    expect(editorSource).toContain('every IPv4 interface of the Device')
    expect(editorSource).toContain('clearing the box keeps the current bind')
  })

  test('the compose app editor edits the address the compose document stores', () => {
    const detailSource = readFileSync(
      resolve(import.meta.dir, '../views/VMDetailView.vue'),
      'utf8',
    )
    expect(detailSource).toContain('<PortForwardEditor v-model="appPortsDraft" bind-field="hostIP" />')
  })
})

describe('docs describe what the console actually does', () => {
  const docs = readFileSync(resolve(import.meta.dir, '../../../docs/using-networks.md'), 'utf8')

  test('clearing a bind is documented as keeping it, not widening it', () => {
    expect(docs).toContain('**keeps that bind**')
    expect(docs).toContain('to publish on every IPv4 interface instead, type `0.0.0.0`')
  })

  test('the spec-only inheritance and rejection rules are not claimed for the console', () => {
    // Those describe the spec PUT/PATCH path. The console's flat PATCH stores
    // the list verbatim, so claiming them there would be wrong.
    expect(docs).not.toContain('rejected rather than guessing which publish')
  })
})
