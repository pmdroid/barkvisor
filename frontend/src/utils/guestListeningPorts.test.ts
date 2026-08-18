import { describe, expect, test } from 'bun:test'
import type { GuestListeningPort } from '../api/types'
import {
  guestListeningPortAccessLabel,
  guestListeningPortHref,
  isLoopbackAddress,
  isWildcardAddress,
} from './guestListeningPorts'

function port(partial: Partial<GuestListeningPort> & Pick<GuestListeningPort, 'port'>): GuestListeningPort {
  return {
    proto: 'tcp',
    address: '0.0.0.0',
    scope: 'network',
    label: null,
    ...partial,
  }
}

describe('guestListeningPorts (PAS-225)', () => {
  test('loopback is internal and never a URL', () => {
    expect(isLoopbackAddress('127.0.0.1')).toBe(true)
    expect(isLoopbackAddress('::1')).toBe(true)
    expect(isWildcardAddress('0.0.0.0')).toBe(true)
    expect(guestListeningPortHref(port({
      address: '127.0.0.1',
      port: 80,
      scope: 'internal',
      label: 'HTTP',
    }), ['10.0.0.5'])).toBeNull()
    expect(guestListeningPortAccessLabel(port({
      address: '127.0.0.1',
      port: 3000,
      scope: 'internal',
      label: 'Dev',
    }))).toBe('Internal')
  })

  test('HTTP on all interfaces uses the guest IP as a URL', () => {
    expect(guestListeningPortHref(port({
      address: '0.0.0.0',
      port: 80,
      label: 'HTTP',
    }), ['10.0.0.5'])).toBe('http://10.0.0.5')
    expect(guestListeningPortHref(port({
      address: '::',
      port: 443,
      label: 'HTTPS',
    }), ['2001:db8::1'])).toBe('https://[2001:db8::1]')
    expect(guestListeningPortHref(port({
      address: '10.0.0.5',
      port: 3000,
      label: 'Dev',
    }), ['10.0.0.5'])).toBe('http://10.0.0.5:3000')
  })

  test('SSH is labeled but not a browser URL', () => {
    expect(guestListeningPortHref(port({
      address: '0.0.0.0',
      port: 22,
      label: 'SSH',
    }), ['10.0.0.5'])).toBeNull()
  })

  test('null means unavailable and empty means none at the type layer', () => {
    const unavailable: GuestListeningPort[] | null = null
    const none: GuestListeningPort[] = []
    expect(unavailable).toBeNull()
    expect(none).toEqual([])
  })
})
