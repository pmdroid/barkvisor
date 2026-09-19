import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  TERMINAL_CLEAN_CLOSE_CODES,
  TERMINAL_MAX_FRAME_BYTES,
  TERMINAL_SERVICE_QUERY,
  saneTerminalWindowSize,
  terminalNewShellDivider,
  terminalPasteChunks,
  terminalResizeFrame,
  terminalSocketPath,
  terminalSocketQuery,
  deviceTerminalSocketPath,
  deviceTerminalSocketQuery,
} from './terminalSocket'
import { deviceVmContainersPath, deviceVmTerminalPath } from './homeDeviceApi'

const here = dirname(fileURLToPath(import.meta.url))
const self = { hostId: 'desk-1', role: 'self', reachability: 'ok' }
const member = { hostId: 'peer/1', role: 'member', reachability: 'ok' }

const panel = readFileSync(join(here, '../components/TerminalPanel.vue'), 'utf8')
const devicePanel = readFileSync(join(here, '../components/DeviceTerminalPanel.vue'), 'utf8')
const detailView = readFileSync(join(here, '../views/VMDetailView.vue'), 'utf8')

const decoder = new TextDecoder()

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
    expect(deviceTerminalSocketPath(self)).toBe('/system/terminal')
    expect(deviceTerminalSocketPath(member)).toBe('/home/devices/peer%2F1/v1/system/terminal')
    expect(deviceTerminalSocketQuery('tix')).toBe('ticket=tix')
    expect(deviceTerminalSocketQuery('tix', 'home-session', { cols: 120, rows: 32 })).toBe(
      'ticket=tix&session=home-session&cols=120&rows=32',
    )
    expect(deviceTerminalSocketQuery('tix', 'home-session')).not.toContain('user=')
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
    expect(panel).toContain('mintStreamTickets(props.vmId, props.device)')
    expect(panel).toContain('terminalSocketPath(props.device, props.vmId)')
    expect(panel).toContain('terminalSocketQuery(ticket, props.service, session, size)')
    expect(panel).toContain('terminalResizeFrame(cols, rows)')
    expect(panel).toContain('terminalPasteChunks(data)')
    expect(panel).not.toContain('token=')
  })

  test('device terminal panel mints a user ticket and never puts user on the socket URL', () => {
    expect(devicePanel).toContain('mintDeviceTerminalTickets(props.osUser, props.device)')
    expect(devicePanel).toContain('deviceTerminalSocketPath(props.device)')
    expect(devicePanel).toContain('deviceTerminalSocketQuery(ticket, session, size)')
    expect(devicePanel).not.toContain('user=')
    expect(devicePanel).not.toContain('token=')
  })
})

describe('terminalSocket (#614): initial grid on the connect URL', () => {
  test('measured size rides cols/rows so the pre-spawn resize race cannot strand 80×24', () => {
    const query = terminalSocketQuery('t-1', 'web', null, { cols: 132, rows: 41 })
    expect(query).toContain('ticket=t-1')
    expect(query).toContain('service=web')
    expect(query).toContain('cols=132')
    expect(query).toContain('rows=41')
    expect(query).not.toContain('session=')
  })

  test('garbage sizes are dropped, never forwarded', () => {
    expect(saneTerminalWindowSize({ cols: 0, rows: 30 })).toBeNull()
    expect(saneTerminalWindowSize({ cols: 120, rows: -2 })).toBeNull()
    expect(saneTerminalWindowSize({ cols: Number.NaN, rows: 30 })).toBeNull()
    expect(saneTerminalWindowSize({ cols: 120, rows: 1e9 })).toBeNull()
    expect(saneTerminalWindowSize(null)).toBeNull()
    expect(saneTerminalWindowSize({ cols: 120.7, rows: 30.2 })).toEqual({ cols: 120, rows: 30 })
    const query = terminalSocketQuery('t-1', 'web', 'sess', { cols: 0, rows: 0 })
    expect(query).not.toContain('cols=')
    expect(query).not.toContain('rows=')
    expect(query).toContain('session=sess')
  })
})

describe('terminalSocket (#614): paste chunking', () => {
  test('small input stays one frame', () => {
    const chunks = terminalPasteChunks('ls -la\r')
    expect(chunks.length).toBe(1)
    expect(decoder.decode(chunks[0])).toBe('ls -la\r')
  })

  test('empty input sends nothing', () => {
    expect(terminalPasteChunks('')).toEqual([])
  })

  test('oversized pastes split under the frame cap and round-trip whole', () => {
    const pasted = '€漢字ab'.repeat(6_000) // ~108 KB UTF-8, well past 16 KiB
    const bytes = new TextEncoder().encode(pasted).byteLength
    expect(bytes).toBeGreaterThan(TERMINAL_MAX_FRAME_BYTES)
    const chunks = terminalPasteChunks(pasted)
    expect(chunks.length).toBeGreaterThan(1)
    for (const chunk of chunks) {
      expect(chunk.byteLength).toBeLessThanOrEqual(TERMINAL_MAX_FRAME_BYTES)
    }
    // Multi-byte code points never torn: decoding each frame standalone is legal.
    expect(chunks.map(c => decoder.decode(c)).join('')).toBe(pasted)
  })

  test('a single code point larger than the cap still forms one chunk', () => {
    const chunk = terminalPasteChunks('𝄐', 2)
    expect(chunk.length).toBe(1)
    expect(decoder.decode(chunk[0])).toBe('𝄐')
  })
})

describe('terminalSocket (#614): reconnect machine contracts', () => {
  test('only the clean-close code stops the reconnect ladder', () => {
    expect(TERMINAL_CLEAN_CLOSE_CODES.has(1000)).toBeTrue()
    expect(TERMINAL_CLEAN_CLOSE_CODES.has(1006)).toBeFalse()
    expect(TERMINAL_CLEAN_CLOSE_CODES.has(1011)).toBeFalse()
  })

  test('new-shell divider names the reconnect and is dim-separated', () => {
    expect(terminalNewShellDivider(0)).toContain('── new shell ──')
    expect(terminalNewShellDivider(3)).toContain('reconnect 3')
  })

  test('panel skips reconnect on clean close and shows the reason', () => {
    expect(panel).toContain('TERMINAL_CLEAN_CLOSE_CODES.has(e.code)')
    expect(panel).toContain("'Shell closed'")
    // The clean branch returns before the reconnect ladder.
    const cleanBranch = panel.slice(
      panel.indexOf('TERMINAL_CLEAN_CLOSE_CODES.has(e.code)'),
      panel.indexOf('scheduleReconnect(`Disconnected'),
    )
    expect(cleanBranch).toContain('return')
  })

  test('panel carries the disposed flag and in-flight guard', () => {
    expect(panel).toContain('let disposed = false')
    expect(panel).toContain('let connecting = false')
    expect(panel).toContain('if (disposed || connecting) return')
    // Unmount disarms the socket callbacks *before* close() so our own teardown
    // close cannot ghost-reconnect a dead component.
    const unmount = panel.slice(panel.indexOf('onUnmounted('))
    expect(unmount).toContain('disposed = true')
    expect(unmount.indexOf('socket.onclose = null')).toBeLessThan(
      unmount.indexOf('socket.close()'),
    )
  })

  test('panel renders server text frames instead of swallowing them', () => {
    expect(panel).toContain("typeof e.data === 'string'")
    const msgHandler = panel.slice(
      panel.indexOf('socket.onmessage'),
      panel.indexOf('socket.onclose'),
    )
    expect(msgHandler).toContain('target.write(new TextEncoder().encode(e.data))')
    expect(msgHandler).not.toContain('return // control frames')
  })

  test('panel resizes from both ready and open and chunks pastes', () => {
    const ready = panel.slice(panel.indexOf('function onReady'), panel.indexOf('function sendResize'))
    expect(ready).toContain('sendResize(instance.cols, instance.rows)')
    const open = panel.slice(panel.indexOf('socket.onopen'), panel.indexOf('socket.onerror'))
    expect(open).toContain('sendResize(wt.cols, wt.rows)')
    expect(open).toContain('terminalNewShellDivider(attempt)')
    const onData = panel.slice(panel.indexOf('function onData'), panel.indexOf('function onResize'))
    expect(onData).toContain('terminalPasteChunks(data)')
  })

  test('active terminal follows live output without resizing its PTY per frame', () => {
    expect(panel).toContain('function followLiveOutput()')
    const messageHandler = panel.slice(
      panel.indexOf('socket.onmessage'),
      panel.indexOf('socket.onclose'),
    )
    expect(messageHandler.match(/followLiveOutput\(\)/g)?.length).toBe(2)
    const follow = panel.slice(panel.indexOf('function followLiveOutput()'), panel.indexOf('function onTermError'))
    expect(follow).toContain('wt.element.scrollTop = wt.element.scrollHeight')
    expect(follow).not.toContain('wt.resize(')
  })

  test('isAlive drops stopping so a shutting-down app cannot spawn shell storms', () => {
    expect(panel).toContain('const isAlive = () => props.vmState ===')
    expect(panel).not.toContain("vmState === 'stopping'")
  })

  test('mint failures retry on the backoff ladder', () => {
    const mintCatch = panel.slice(panel.indexOf('Ticket failed'))
    expect(mintCatch).toContain('scheduleReconnect(')
  })

  test('detail view keeps the panel mounted across tab switches (scrollback)', () => {
    expect(detailView).toContain('terminalOpenedOnce')
    expect(detailView).toContain('v-if="terminalOpenedOnce && isApp && showMemberConnect"')
    expect(detailView).toContain("v-show=\"tab === 'terminal'\"")
    // The old remount-on-tab-switch shape must be gone for the terminal sheet.
    expect(detailView).not.toContain(`v-if="tab === 'terminal' && isApp && showMemberConnect"`)
  })
})
