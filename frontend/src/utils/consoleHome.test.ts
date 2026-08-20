import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  canConnectDeviceConsole,
  consoleSocketPath,
  consoleSocketQuery,
  deviceVmConsolePath,
  deviceVmVncPath,
  deviceWsTicketPath,
  vncWindowPath,
  wsTicketPath,
} from './consoleHome'

const here = dirname(fileURLToPath(import.meta.url))
const self = { hostId: 'desk-1', role: 'self', reachability: 'ok' }
const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }
const down = { hostId: 'peer-2', role: 'member', reachability: 'unreachable' }

describe('consoleHome (PAS-200)', () => {
  test('ticket and sockets go through Home for members, local for self', () => {
    expect(deviceWsTicketPath(self)).toBe('/auth/ws-ticket')
    expect(deviceWsTicketPath(member)).toBe('/home/devices/peer%2F1/v1/auth/ws-ticket')
    expect(wsTicketPath(undefined)).toBe('/auth/ws-ticket')
    expect(wsTicketPath(self)).toBe('/auth/ws-ticket')
    expect(wsTicketPath(member)).toBe('/home/devices/peer%2F1/v1/auth/ws-ticket')
    expect(deviceVmVncPath(self, 'vm-9')).toBe('/vms/vm-9/vnc')
    expect(deviceVmConsolePath(self, 'vm-9')).toBe('/vms/vm-9/console')
    expect(deviceVmVncPath(member, 'vm-9')).toBe('/home/devices/peer%2F1/v1/vms/vm-9/vnc')
    expect(deviceVmConsolePath(member, 'vm-9')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/console',
    )
    expect(consoleSocketPath(undefined, 'vm-9', 'vnc')).toBe('/vms/vm-9/vnc')
    expect(consoleSocketPath(member, 'vm-9', 'console')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/console',
    )
    expect(vncWindowPath(self, 'vm-9')).toBe('/vms/vm-9/vnc')
    expect(vncWindowPath(undefined, 'vm-9')).toBe('/vms/vm-9/vnc')
    expect(vncWindowPath(member, 'vm-9')).toBe('/devices/peer%2F1/vms/vm-9/vnc')
  })

  test('unreachable members hide Connect; self still connects', () => {
    expect(canConnectDeviceConsole(self)).toBe(true)
    expect(canConnectDeviceConsole({ ...self, reachability: 'unreachable' })).toBe(true)
    expect(canConnectDeviceConsole(member)).toBe(true)
    expect(canConnectDeviceConsole(down)).toBe(false)
    expect(canConnectDeviceConsole(null)).toBe(false)
  })

  test('member sockets send Home session ticket; self stays ticket-only', () => {
    expect(consoleSocketQuery('member-ticket', 'home-session')).toContain('ticket=member-ticket')
    expect(consoleSocketQuery('member-ticket', 'home-session')).toContain('session=home-session')
    expect(consoleSocketQuery('member-ticket', 'home-session')).not.toContain('token=')
    expect(consoleSocketQuery('local-ticket')).toBe('ticket=local-ticket')
    expect(consoleSocketQuery('local-ticket', null)).toBe('ticket=local-ticket')
  })

  test('SPA mints the ticket on the member and opens Home WS with hostId', () => {
    const client = readFileSync(join(here, '../api/client.ts'), 'utf8')
    const vnc = readFileSync(join(here, '../components/VNCPanel.vue'), 'utf8')
    const serial = readFileSync(join(here, '../components/ConsolePanel.vue'), 'utf8')
    const detail = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')
    const window = readFileSync(join(here, '../views/VNCWindowView.vue'), 'utf8')
    const router = readFileSync(join(here, '../router/index.ts'), 'utf8')
    expect(client).toContain('wsTicketPath(device)')
    expect(client).toContain('mintStreamTickets')
    expect(client).toContain('needsHomeSession(device)')
    expect(vnc).toContain('mintStreamTickets(props.vmId, props.device)')
    expect(vnc).toContain("consoleSocketPath(props.device, props.vmId, 'vnc')")
    expect(vnc).toContain('consoleSocketQuery(ticket, session)')
    expect(serial).toContain('mintStreamTickets(props.vmId, props.device)')
    expect(serial).toContain("consoleSocketPath(props.device, props.vmId, 'console')")
    expect(serial).toContain('consoleSocketQuery(ticket, session)')
    expect(detail).toContain('canConnectDeviceConsole')
    expect(detail).toContain('showMemberConnect')
    expect(detail).toContain('vncWindowPath')
    expect(detail).toContain(':device="isMemberDetail ? memberDevice : undefined"')
    expect(window).toContain('canConnectDeviceConsole')
    expect(window).toContain(':device="memberDevice"')
    expect(window).toContain(':key="`${hostId}-${vmId}`"')
    expect(window).toContain("error.value = 'Device not found'")
    expect(window).toContain('isNotFoundError')
    expect(window).toContain('homeWorkloads.removeOne')
    expect(window).toContain("error.value = 'Workload not found on that Device'")
    expect(window).not.toMatch(/if \(target && !isSelfDevice/)
    expect(router).toContain("path: '/devices/:hostId/vms/:id/vnc'")
    expect(detail).not.toContain("!isMemberDetail && tab === 'console'")
    expect(vnc).not.toMatch(/\/api\/vms\/\$\{props\.vmId\}\/vnc/)
  })
})
