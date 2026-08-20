import { isSelfDevice, type DeviceApiTarget } from './homeDeviceApi'

/** Query contract for stream sockets. Matches BarkVisorCore StreamTicketPolicy. */
export const STREAM_TICKET_QUERY = 'ticket'
export const STREAM_SESSION_QUERY = 'session'

/** Member tunnels need a Home-minted session. This Device does not. */
export function needsHomeSession(device?: DeviceApiTarget | null): boolean {
  return Boolean(device && !isSelfDevice(device))
}

/** `ticket=` plus optional Home `session=`. Never JWT, never noVNC `token=`. */
export function streamSocketQuery(ticket: string, session?: string | null): string {
  const params = new URLSearchParams({ [STREAM_TICKET_QUERY]: ticket })
  if (session) params.set(STREAM_SESSION_QUERY, session)
  return params.toString()
}
