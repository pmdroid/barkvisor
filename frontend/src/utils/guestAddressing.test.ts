import { describe, expect, test } from 'bun:test'
import {
  cloudInitApplies,
  macReservationCopy,
  payloadGuestAddressing,
  staticRefusedCopy,
  validateGuestAddressing,
} from './guestAddressing'

describe('guestAddressing (#385)', () => {
  test('DHCP is omitted from create payload', () => {
    expect(payloadGuestAddressing({
      bridged: true,
      cloudInit: true,
      mode: 'dhcp',
      ipv4: '192.168.1.40',
      prefixLength: 24,
      gateway: '192.168.1.1',
      nameservers: '1.1.1.1',
    })).toBeUndefined()
  })

  test('static is only sent for bridged cloud-init', () => {
    const fields = {
      mode: 'static' as const,
      ipv4: '192.168.1.40',
      prefixLength: 24,
      gateway: '192.168.1.1',
      nameservers: '1.1.1.1, 8.8.8.8',
    }
    expect(payloadGuestAddressing({ bridged: false, cloudInit: true, ...fields })).toBeUndefined()
    expect(payloadGuestAddressing({ bridged: true, cloudInit: false, ...fields })).toBeUndefined()
    expect(payloadGuestAddressing({ bridged: true, cloudInit: true, ...fields })).toEqual({
      mode: 'static',
      ipv4: '192.168.1.40',
      prefixLength: 24,
      gateway: '192.168.1.1',
      nameservers: ['1.1.1.1', '8.8.8.8'],
    })
  })

  test('copy never pretends an installer ISO was configured', () => {
    expect(macReservationCopy({ bridged: true, cloudInit: false })).toContain('did not configure the OS')
    expect(staticRefusedCopy({ bridged: false, cloudInit: true })).toContain('port forwards')
    expect(cloudInitApplies({ mode: 'iso' })).toBe(false)
    expect(cloudInitApplies({ mode: 'cloud' })).toBe(true)
    expect(cloudInitApplies({ mode: 'iso', cloudInitPath: '/data/cidata.iso' })).toBe(true)
  })

  test('static fields are checked client-side', () => {
    expect(validateGuestAddressing({ mode: 'dhcp' })).toBeNull()
    expect(validateGuestAddressing({
      mode: 'static', ipv4: '192.168.1.40', prefixLength: 24, gateway: '192.168.1.1',
    })).toBeNull()
    expect(validateGuestAddressing({
      mode: 'static', ipv4: 'nope', prefixLength: 24, gateway: '192.168.1.1',
    })).toBeTruthy()
  })
})
