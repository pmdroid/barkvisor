import { describe, expect, test } from 'bun:test'
import { healthLabel, vmHealth } from './workloadHealth'
import type { VM } from '../api/types'

function vm(partial: Partial<VM> & Pick<VM, 'state'>): VM {
  return {
    id: 'vm-1',
    name: 'n',
    vmType: 'linux-arm64',
    cpuCount: 1,
    memoryMB: 512,
    bootDiskId: 'd',
    isoId: null,
    isoIds: null,
    networkId: null,
    cloudInitPath: null,
    description: null,
    bootOrder: null,
    displayResolution: null,
    additionalDiskIds: null,
    uefi: false,
    tpmEnabled: false,
    macAddress: null,
    sharedPaths: null,
    portForwards: null,
    usbDevices: null,
    pendingChanges: false,
    createdAt: '2026-01-01T00:00:00Z',
    updatedAt: '2026-01-01T00:00:00Z',
    ...partial,
  }
}

describe('vmHealth', () => {
  test('prefers the API health badge field', () => {
    expect(vmHealth(vm({ state: 'running', health: 'degraded' }))).toBe('degraded')
  })

  test('running without guest agent is running not failed', () => {
    expect(vmHealth(vm({ state: 'running', health: 'running' }))).toBe('running')
    expect(vmHealth(vm({ state: 'running' }))).toBe('running')
  })

  test('error state falls back to failed', () => {
    expect(vmHealth(vm({ state: 'error' }))).toBe('failed')
  })
})

describe('healthLabel', () => {
  test('guest_ready is humanized', () => {
    expect(healthLabel('guest_ready')).toBe('Guest ready')
    expect(healthLabel('failed')).toBe('Failed')
  })
})
