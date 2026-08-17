import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  isMemberWorkloadDetail,
  localNetworkForDetail,
  memberNetworkCaption,
  openWorkloadRow,
  workloadDetailPath,
  workloadDetailVmSource,
  workloadRowKey,
} from './workloadDetail'

const here = dirname(fileURLToPath(import.meta.url))

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

describe('member detail role (PAS-202)', () => {
  test('unknown role is not member-restricted until health settles', () => {
    expect(isMemberWorkloadDetail({ hostId: '', role: undefined })).toBe(false)
    expect(isMemberWorkloadDetail({ hostId: 'desk-1', role: undefined })).toBe(false)
    expect(isMemberWorkloadDetail({ hostId: 'desk-1', role: undefined, loadSettled: false })).toBe(false)
    expect(isMemberWorkloadDetail({ hostId: 'desk-1', role: 'self' })).toBe(false)
    expect(isMemberWorkloadDetail({ hostId: 'desk-1', role: 'self', loadSettled: true })).toBe(false)
    expect(isMemberWorkloadDetail({ hostId: 'orb', role: 'member' })).toBe(true)
    expect(isMemberWorkloadDetail({ hostId: 'orb', role: 'member', loadSettled: false })).toBe(true)
    expect(isMemberWorkloadDetail({ hostId: 'gone', role: undefined, loadSettled: true })).toBe(true)
  })

  test('self hostId does not bind a cached VM until role is known', () => {
    expect(workloadDetailVmSource({ hostId: '', role: undefined })).toBe('local')
    expect(workloadDetailVmSource({ hostId: 'desk-1', role: undefined })).toBe('pending')
    expect(workloadDetailVmSource({ hostId: 'desk-1', role: 'self' })).toBe('local')
    expect(workloadDetailVmSource({ hostId: 'orb', role: 'member' })).toBe('member')
    expect(workloadDetailVmSource({ hostId: 'orb', role: undefined })).toBe('pending')
  })

  test('VMDetailView evicts only on 404 and keeps memberLoadError without a VM', () => {
    const view = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')
    expect(view).toContain('isNotFoundError')
    expect(view).toContain('isMemberWorkloadDetail')
    expect(view).toContain('workloadDetailVmSource')
    expect(view).toMatch(/if \(isNotFoundError\(e\)\) \{\s*homeWorkloads\.removeOne/)
    expect(view).toMatch(/v-if="!vm"[\s\S]*memberLoadError/)
    expect(view).toMatch(/source === 'pending'[\s\S]*return undefined/)
    expect(view).not.toMatch(/refreshOne\([^)]+\)\.catch\(\(\) => \{\}\)/)
    expect(view).toContain('pollMemberDetail')
    expect(view).toMatch(
      /if \(isNotFoundError\(e\)\) \{\s*homeWorkloads\.removeOne[\s\S]*?return/,
    )
    expect(view).toContain('memberLoadError.value = null')
    expect(view).toContain('watch(showMemberConnect')
  })
})
