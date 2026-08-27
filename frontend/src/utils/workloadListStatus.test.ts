import { describe, expect, test } from 'bun:test'
import {
  isPendingCreateId,
  PENDING_CREATE_ID_PREFIX,
  workloadListHealthBucket,
  workloadListStatusClass,
  workloadListStatusLabel,
  workloadListStatusSub,
} from './workloadListStatus'
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

describe('workloadListStatusLabel', () => {
  test('create phases beat collapsed Running', () => {
    expect(workloadListStatusLabel({
      vm: vm({ state: 'provisioning', health: 'starting' }),
      createPhase: 'downloading',
    })).toBe('Downloading')
    expect(workloadListStatusLabel({
      vm: vm({ state: 'provisioning' }),
      createPhase: 'decompressing',
    })).toBe('Decompressing')
    expect(workloadListStatusLabel({
      vm: vm({ state: 'provisioning', health: 'starting' }),
    })).toBe('Provisioning')
    expect(workloadListStatusLabel({
      vm: vm({ state: 'starting', health: 'starting' }),
    })).toBe('Starting')
  })

  test('steady states stay short', () => {
    expect(workloadListStatusLabel({ vm: vm({ state: 'running', health: 'running' }) })).toBe('Running')
    expect(workloadListStatusLabel({ vm: vm({ state: 'running', health: 'guest_ready' }) })).toBe('Running')
    expect(workloadListStatusLabel({ vm: vm({ state: 'stopped', health: 'stopped' }) })).toBe('Stopped')
    expect(workloadListStatusLabel({ vm: vm({ state: 'error', health: 'failed' }) })).toBe('Failed')
  })
})

describe('workloadListStatusSub', () => {
  test('shows download percent on the create detail', () => {
    expect(workloadListStatusSub({
      vm: vm({ state: 'provisioning' }),
      createPhase: 'downloading',
      createDetail: 'Downloading image',
      createPercent: 41,
    })).toBe('Downloading image · 41%')
  })

  test('unreachable wins when there is no create detail', () => {
    expect(workloadListStatusSub({
      vm: vm({ state: 'stopped' }),
      reachable: false,
    })).toBe('Device unreachable')
  })
})

describe('workloadListStatusClass', () => {
  test('in-flight create is warn, not Running ok', () => {
    expect(workloadListStatusClass({
      vm: vm({ state: 'provisioning', health: 'starting' }),
    })).toBe('warn')
    expect(workloadListHealthBucket({
      vm: vm({ state: 'provisioning' }),
      createPhase: 'downloading',
    })).toBe('running')
    expect(workloadListStatusClass({
      vm: vm({ state: 'running', health: 'running' }),
    })).toBe('ok')
  })
})

test('pending create ids', () => {
  expect(isPendingCreateId(`${PENDING_CREATE_ID_PREFIX}abc`)).toBe(true)
  expect(isPendingCreateId('vm-1')).toBe(false)
})
