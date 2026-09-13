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

/** Self stays on /vms/:id/terminal; members ride the Home tunnel. */
export function terminalSocketPath(
  device: DeviceApiTarget | null | undefined,
  vmId: string,
): string {
  const target = device ?? { hostId: 'self', role: 'self' }
  return deviceVmTerminalPath(target, vmId)
}

/** `ticket=` + `service=` plus optional Home `session=`. Never JWT. */
export function terminalSocketQuery(
  ticket: string,
  service: string,
  session?: string | null,
): string {
  const params = new URLSearchParams({
    [STREAM_TICKET_QUERY]: ticket,
    [TERMINAL_SERVICE_QUERY]: service,
  })
  if (session) params.set(STREAM_SESSION_QUERY, session)
  return params.toString()
}

/** Resize control frame, sent as a WebSocket text frame; bytes stay binary. */
export function terminalResizeFrame(cols: number, rows: number): string {
  return JSON.stringify({ type: 'resize', cols, rows })
}
