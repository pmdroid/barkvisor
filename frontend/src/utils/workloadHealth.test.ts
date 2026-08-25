import { describe, expect, test } from 'bun:test'
import { applyVMStateEvent, filterRowsByHealth, healthFromState, healthLabel, vmHealth, vmListEmptyKind } from './workloadHealth'
import type { VM, VMRuntimeStatus } from '../api/types'

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

describe('healthFromState', () => {
  test('maps lifecycle states to health badges', () => {
    expect(healthFromState('error')).toBe('failed')
    expect(healthFromState('starting')).toBe('starting')
    expect(healthFromState('provisioning')).toBe('starting')
    expect(healthFromState('running')).toBe('running')
    expect(healthFromState('stopping')).toBe('running')
    expect(healthFromState('stopped')).toBe('stopped')
    expect(healthFromState('deleting')).toBe('stopped')
    expect(healthFromState('mystery')).toBe('unknown')
  })
})

describe('applyVMStateEvent', () => {
  function status(partial: Partial<VMRuntimeStatus> = {}): VMRuntimeStatus {
    return {
      state: 'running',
      pendingChanges: false,
      generation: 1,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
      health: 'running',
      healthError: null,
      ...partial,
    }
  }

  test('overwrites stale health so a kernel-panic SSE updates the pill', () => {
    const machine = vm({
      state: 'running',
      health: 'running',
      status: status(),
    })
    applyVMStateEvent(machine, { state: 'error', error: 'Kernel panic' })
    expect(machine.state).toBe('error')
    expect(machine.health).toBe('failed')
    expect(machine.status?.state).toBe('error')
    expect(machine.status?.health).toBe('failed')
    expect(machine.status?.healthError).toBe('Kernel panic')
    expect(vmHealth(machine)).toBe('failed')
  })

  test('clears healthError when state recovers', () => {
    const machine = vm({
      state: 'error',
      health: 'failed',
      status: status({ state: 'error', health: 'failed', healthError: 'Kernel panic' }),
    })
    applyVMStateEvent(machine, { state: 'running' })
    expect(vmHealth(machine)).toBe('running')
    expect(machine.status?.healthError).toBeNull()
  })

  test('keeps guest_ready on a running SSE event', () => {
    const machine = vm({
      state: 'running',
      health: 'guest_ready',
      status: status({ health: 'guest_ready' }),
    })
    applyVMStateEvent(machine, { state: 'running' })
    expect(machine.health).toBe('guest_ready')
    expect(machine.status?.health).toBe('guest_ready')
    expect(vmHealth(machine)).toBe('guest_ready')
  })

  test('keeps degraded on a running SSE event', () => {
    const machine = vm({
      state: 'running',
      health: 'degraded',
      status: status({ health: 'degraded', healthError: 'HTTP probe failed' }),
    })
    applyVMStateEvent(machine, { state: 'running' })
    expect(machine.health).toBe('degraded')
    expect(machine.status?.health).toBe('degraded')
    expect(machine.status?.healthError).toBe('HTTP probe failed')
    expect(vmHealth(machine)).toBe('degraded')
  })

  test('drops guest_ready when the VM leaves running', () => {
    const machine = vm({
      state: 'running',
      health: 'guest_ready',
      status: status({ health: 'guest_ready' }),
    })
    applyVMStateEvent(machine, { state: 'stopped' })
    expect(machine.health).toBe('stopped')
    expect(vmHealth(machine)).toBe('stopped')
  })
})

describe('healthLabel', () => {
  test('guest_ready is humanized', () => {
    expect(healthLabel('guest_ready')).toBe('Guest ready')
    expect(healthLabel('failed')).toBe('Failed')
    expect(vmHealth(vm({ state: 'running', health: 'guest_ready' }))).toBe('guest_ready')
  })
})

describe('filterRowsByHealth', () => {
  const rows = [
    { vm: vm({ id: 'run', state: 'running', health: 'running' }) },
    { vm: vm({ id: 'fail', state: 'error', health: 'failed' }) },
    { vm: vm({ id: 'stop', state: 'stopped', health: 'stopped' }) },
    { vm: vm({ id: 'deg', state: 'running', health: 'degraded' }) },
  ]

  test('all returns every row', () => {
    expect(filterRowsByHealth(rows, 'all')).toEqual(rows)
  })

  test('running / failed / stopped filter by vmHealth', () => {
    expect(filterRowsByHealth(rows, 'running').map((row) => row.vm.id)).toEqual(['run'])
    expect(filterRowsByHealth(rows, 'failed').map((row) => row.vm.id)).toEqual(['fail'])
    expect(filterRowsByHealth(rows, 'stopped').map((row) => row.vm.id)).toEqual(['stop'])
  })

  test('a health key other than all keeps matching rows', () => {
    expect(filterRowsByHealth(rows, 'degraded').map((row) => row.vm.id)).toEqual(['deg'])
  })
})

describe('vmListEmptyKind', () => {
  test('none when Home has no VMs', () => {
    expect(vmListEmptyKind(0, 0, 'all')).toBe('none')
    expect(vmListEmptyKind(0, 0, 'failed')).toBe('none')
    expect(vmListEmptyKind(3, 0, 'all')).toBe('none')
  })

  test('filtered when a health chip matches nothing', () => {
    expect(vmListEmptyKind(3, 0, 'failed')).toBe('filtered')
    expect(vmListEmptyKind(2, 0, 'running')).toBe('filtered')
    expect(vmListEmptyKind(1, 0, 'stopped')).toBe('filtered')
  })

  test('table when there are matching rows', () => {
    expect(vmListEmptyKind(3, 3, 'all')).toBe('table')
    expect(vmListEmptyKind(3, 1, 'running')).toBe('table')
  })
})
