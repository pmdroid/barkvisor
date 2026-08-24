import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { createPinia, setActivePinia } from 'pinia'
import api from '../api/client'
import type { HomeDeviceHealthReport } from '../api/types'
import { useDevicesStore } from '../stores/devices'
import { DEVICE_LABEL } from './terminology'
import {
  deviceWorkloadLine,
  homeWorkloadsRunningLine,
  reachabilityHint,
  reachabilityLabel,
} from './homeDeviceHealth'

const srcRoot = join(dirname(fileURLToPath(import.meta.url)), '..')
const originalGet = api.get

const memberDownReport: HomeDeviceHealthReport = {
  devices: [
    {
      hostId: 'self-1',
      role: 'self',
      displayName: 'desk',
      reachability: 'ok',
      workloadCount: 2,
      healthCounts: { running: 1, stopped: 1 },
    },
    {
      hostId: 'peer-1',
      role: 'member',
      displayName: 'lab',
      reachability: 'unreachable',
      reachabilityError: 'Device is unreachable',
      resources: null,
      workloadCount: null,
      healthCounts: null,
    },
  ],
  totals: {
    devices: 2,
    reachable: 1,
    unreachable: 1,
    workloadCount: 2,
    healthCounts: { running: 1, stopped: 1 },
  },
}

describe('member-down demo (PAS-47)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    api.get = originalGet
  })

  test('dashboard marks the member unreachable and keeps local counts', async () => {
    api.get = mock(() => Promise.resolve({ data: memberDownReport })) as typeof api.get
    const store = useDevicesStore()
    await store.fetchHealth()

    const peer = store.deviceByHostId('peer-1')
    expect(peer?.reachability).toBe('unreachable')
    expect(peer?.workloadCount ?? null).toBeNull()
    expect(store.selfDevice?.workloadCount).toBe(2)
    expect(store.totals?.unreachable).toBe(1)
    expect(store.totals?.workloadCount).toBe(2)
    expect(deviceWorkloadLine(peer!)).toBe('Health unavailable')
    expect(homeWorkloadsRunningLine(store.totals, 1)).toBe('1 of 2 workloads running')
  })

  test('Device card and drill-down say the member is still running locally', () => {
    expect(reachabilityLabel('unreachable')).toBe('Unreachable')
    expect(reachabilityHint({ reachability: 'unreachable' })).toBe(
      `This ${DEVICE_LABEL.toLowerCase()} is still running locally. The member did not answer.`,
    )
    expect(
      reachabilityHint({
        reachability: 'memberHTTP',
        reachabilityError: 'Device returned HTTP 503',
      }),
    ).toBe('Device returned HTTP 503')

    const card = readFileSync(join(srcRoot, 'components/DeviceCard.vue'), 'utf8')
    expect(card).toContain('reachabilityLabel')
    expect(card).toContain('reachabilityHint')
    expect(card).toContain(DEVICE_LABEL)

    const detail = readFileSync(join(srcRoot, 'views/DeviceDetailView.vue'), 'utf8')
    expect(detail).toContain('reachabilityLabel')
    expect(detail).toContain('reachabilityHint')
    expect(detail).toContain('Workload counts are not shown')
  })
})
