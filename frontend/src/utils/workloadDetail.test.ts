import { describe, expect, test } from 'bun:test'
import {
  localNetworkForDetail,
  memberNetworkCaption,
  openWorkloadRow,
  workloadDetailPath,
  workloadRowKey,
} from './workloadDetail'

describe('openRow (PAS-202)', () => {
  test('self stays on /vms/:id', () => {
    const row = { hostId: 'desk-1', role: 'self', vm: { id: 'vm-1' } }
    expect(workloadDetailPath(row)).toBe('/vms/vm-1')
    expect(workloadRowKey(row)).toBe('desk-1:vm-1')
  })

  test('a member row opens Workload detail, not a Device card', () => {
    const row = { hostId: 'orb', role: 'member', vm: { id: 'vm-2' } }
    expect(workloadDetailPath(row)).toBe('/devices/orb/vms/vm-2')
    expect(workloadDetailPath(row)).not.toBe('/devices/orb')
    expect(workloadRowKey(row)).toBe('orb:vm-2')
  })

  test('hostId:vmId is encoded in the member route', () => {
    const row = { hostId: 'peer/1', role: 'member', vm: { id: 'vm/9' } }
    expect(workloadDetailPath(row)).toBe('/devices/peer%2F1/vms/vm%2F9')
    expect(workloadRowKey(row)).toBe('peer/1:vm/9')
  })

  test('openRow pushes the Workload path', () => {
    const pushed: string[] = []
    openWorkloadRow((path) => {
      pushed.push(path)
    }, { hostId: 'orb', role: 'member', vm: { id: 'wave1' } })
    openWorkloadRow((path) => {
      pushed.push(path)
    }, { hostId: 'desk', role: 'self', vm: { id: 'local' } })
    expect(pushed).toEqual(['/devices/orb/vms/wave1', '/vms/local'])
  })
})

describe('member detail network (PAS-202)', () => {
  const localNAT = { id: 'net-local', name: 'Default NAT', mode: 'nat', isDefault: true }
  const localBridge = { id: 'net-br', name: 'LAN', mode: 'bridged', bridge: 'en0', isDefault: false }

  test('self still resolves from the local inventory', () => {
    expect(localNetworkForDetail(false, 'net-br', [localNAT, localBridge])).toEqual(localBridge)
    expect(localNetworkForDetail(false, null, [localNAT, localBridge])).toEqual(localNAT)
    expect(localNetworkForDetail(false, 'missing', [localNAT, localBridge])).toBeNull()
  })

  test('a member never uses Home name, mode, Default NAT, or bridge status', () => {
    expect(localNetworkForDetail(true, 'net-br', [localNAT, localBridge])).toBeNull()
    expect(localNetworkForDetail(true, 'net-local', [localNAT, localBridge])).toBeNull()
    expect(localNetworkForDetail(true, null, [localNAT, localBridge])).toBeNull()
    expect(memberNetworkCaption('net-orb')).toBe('net-orb')
    expect(memberNetworkCaption(null)).toBe('Unknown')
    expect(memberNetworkCaption(undefined)).toBe('Unknown')
    expect(memberNetworkCaption(null)).not.toBe('Default NAT')
  })
})
