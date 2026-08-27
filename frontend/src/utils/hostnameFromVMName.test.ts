import { describe, expect, test } from 'bun:test'
import { defaultVMNameFromLabel, hostnameFromVMName } from './hostnameFromVMName'

describe('hostnameFromVMName', () => {
  test('slugifies display names', () => {
    expect(hostnameFromVMName('Ubuntu Server')).toBe('ubuntu-server')
    expect(hostnameFromVMName('  Pi-hole  ')).toBe('pi-hole')
    expect(hostnameFromVMName('My---VM')).toBe('my-vm')
  })

  test('default VM name adds suffix', () => {
    expect(defaultVMNameFromLabel('Ubuntu Server')).toBe('ubuntu-server-1')
  })
})
