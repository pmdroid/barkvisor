import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  TERMINAL_SERVICE_QUERY,
  terminalResizeFrame,
  terminalSocketPath,
  terminalSocketQuery,
} from './terminalSocket'
import { deviceVmContainersPath, deviceVmTerminalPath } from './homeDeviceApi'

const here = dirname(fileURLToPath(import.meta.url))
const self = { hostId: 'desk-1', role: 'self', reachability: 'ok' }
const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }

describe('terminalSocket (#609)', () => {
  test('paths stay local for self and ride Home for members', () => {
    expect(deviceVmTerminalPath(self, 'vm-9')).toBe('/vms/vm-9/terminal')
    expect(deviceVmContainersPath(self, 'vm-9')).toBe('/vms/vm-9/containers')
    expect(deviceVmTerminalPath(member, 'vm-9')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/terminal',
    )
    expect(deviceVmContainersPath(member, 'vm-9')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/containers',
    )
    expect(terminalSocketPath(undefined, 'vm-9')).toBe('/vms/vm-9/terminal')
    expect(terminalSocketPath(self, 'vm-9')).toBe('/vms/vm-9/terminal')
    expect(terminalSocketPath(member, 'vm-9')).toBe(
      '/home/devices/peer%2F1/v1/vms/vm-9/terminal',
    )
  })

  test('query carries ticket and service; members add the Home session', () => {
    expect(TERMINAL_SERVICE_QUERY).toBe('service')
    expect(terminalSocketQuery('local-ticket', 'bv-web-1')).toBe(
      'ticket=local-ticket&service=bv-web-1',
    )
    const memberQuery = terminalSocketQuery('member-ticket', 'bv-db.2', 'home-session')
    expect(memberQuery).toContain('ticket=member-ticket')
    expect(memberQuery).toContain('service=bv-db.2')
    expect(memberQuery).toContain('session=home-session')
    expect(memberQuery).not.toContain('token=')
  })

  test('resize control frame is JSON text for the PTY winsize', () => {
    expect(JSON.parse(terminalResizeFrame(120, 40))).toEqual({
      type: 'resize',
      cols: 120,
      rows: 40,
    })
  })

  test('panel reuses the one-use ticket mint and binary stdin contract', () => {
    const panel = readFileSync(join(here, '../components/TerminalPanel.vue'), 'utf8')
    expect(panel).toContain('mintStreamTickets(props.vmId, props.device)')
    expect(panel).toContain('terminalSocketPath(props.device, props.vmId)')
    expect(panel).toContain('terminalSocketQuery(ticket, props.service, session)')
    expect(panel).toContain('terminalResizeFrame(cols, rows)')
    expect(panel).toContain('new TextEncoder().encode(data)')
    expect(panel).not.toContain('token=')
  })
})
