/** Admin workload exec terminal (#609). One-use ticket contract like the serial
 *  console; `service=` names the compose service whose container we exec into. */

import {
  deviceVmContainersPath,
  deviceVmTerminalPath,
  type DeviceApiTarget,
} from './homeDeviceApi'
import { STREAM_SESSION_QUERY, STREAM_TICKET_QUERY } from './streamTicket'

export { deviceVmContainersPath, deviceVmTerminalPath }

export const TERMINAL_SERVICE_QUERY = 'service'
export const TERMINAL_COLS_QUERY = 'cols'
export const TERMINAL_ROWS_QUERY = 'rows'

/** websocket-kit drops inbound frames past ~16 KiB; the daemon chunks
 *  server→client the same way. Keep client→server pastes under the cap
 *  so a big paste is not severed mid-frame (#614). */
export const TERMINAL_MAX_FRAME_BYTES = 12_288

/** Clean-close codes whose shell exit the reconnect machine must honor by
 *  *not* dialing again: deliberate `exit`, stopped app, admin close (#614). */
export const TERMINAL_CLEAN_CLOSE_CODES: ReadonlySet<number> = new Set([1000])

/** Self stays on /vms/:id/terminal; members ride the Home tunnel. */
export function terminalSocketPath(
  device: DeviceApiTarget | null | undefined,
  vmId: string,
): string {
  const target = device ?? { hostId: 'self', role: 'self' }
  return deviceVmTerminalPath(target, vmId)
}

export interface TerminalWindowSize {
  cols: number
  rows: number
}

/** `ticket=` + `service=` plus the measured grid (`cols`/`rows`, #614 — the
 *  daemon spawns the PTY from these so the first resize race cannot strand an
 *  80×24 shell) plus optional Home `session=`. Never JWT. */
export function terminalSocketQuery(
  ticket: string,
  service: string,
  session?: string | null,
  size?: TerminalWindowSize | null,
): string {
  const params = new URLSearchParams({
    [STREAM_TICKET_QUERY]: ticket,
    [TERMINAL_SERVICE_QUERY]: service,
  })
  if (session) params.set(STREAM_SESSION_QUERY, session)
  const sane = saneTerminalWindowSize(size)
  if (sane) {
    params.set(TERMINAL_COLS_QUERY, String(sane.cols))
    params.set(TERMINAL_ROWS_QUERY, String(sane.rows))
  }
  return params.toString()
}

/** Grid sizes the daemon will accept; garbage/oversized queries fall back to
 *  the server-side PTY default rather than pinning the session to nonsense. */
export const TERMINAL_MAX_WINDOW_DIMENSION = 9999

export function saneTerminalWindowSize(
  size: TerminalWindowSize | null | undefined,
): TerminalWindowSize | null {
  if (!size) return null
  if (!Number.isFinite(size.cols) || !Number.isFinite(size.rows)) return null
  if (size.cols < 1 || size.rows < 1 || size.cols > TERMINAL_MAX_WINDOW_DIMENSION || size.rows > TERMINAL_MAX_WINDOW_DIMENSION) {
    return null
  }
  return { cols: Math.trunc(size.cols), rows: Math.trunc(size.rows) }
}

/** Resize control frame, sent as a WebSocket text frame; bytes stay binary. */
export function terminalResizeFrame(cols: number, rows: number): string {
  return JSON.stringify({ type: 'resize', cols, rows })
}

/** Split typed/pasted input into UTF-8 chunks that fit one WebSocket frame.
 *  Encoding per chunk (not one encode + byte slices) keeps multi-byte code
 *  points whole, so the container TTY never sees a torn sequence. */
export function terminalPasteChunks(
  data: string,
  maxBytes: number = TERMINAL_MAX_FRAME_BYTES,
): Uint8Array[] {
  const encoder = new TextEncoder()
  const chunks: Uint8Array[] = []
  let buffer = ''
  let bufferBytes = 0
  for (const char of data) {
    const charBytes = encoder.encode(char).byteLength
    if (bufferBytes + charBytes > maxBytes && buffer) {
      chunks.push(encoder.encode(buffer))
      buffer = ''
      bufferBytes = 0
    }
    buffer += char
    bufferBytes += charBytes
  }
  if (buffer) chunks.push(encoder.encode(buffer))
  return chunks
}

/** Divider written to the grid when a reconnect spawns a fresh shell, so
 *  scrollback from the dead session stays readable but clearly separated. */
export function terminalNewShellDivider(attempt: number): string {
  return `\r\n\x1b[2m── new shell${attempt > 0 ? ` (reconnect ${attempt})` : ''} ──\x1b[0m\r\n`
}
