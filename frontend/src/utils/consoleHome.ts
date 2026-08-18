/** Home VNC / serial console (PAS-200).
 *  Ticket is minted on the owning Device. SPA talks to Home with hostId+vmId.
 *  Unreachable members hide Connect — they do not open a dead socket. */

import {
  canFetchDeviceWorkloads,
  deviceVmConsolePath,
  deviceVmVncPath,
  deviceWsTicketPath,
  isSelfDevice,
  type DeviceApiTarget,
} from './homeDeviceApi'

export { deviceVmConsolePath, deviceVmVncPath, deviceWsTicketPath }

export function canConnectDeviceConsole(
  device: DeviceApiTarget | null | undefined,
): boolean {
  return Boolean(device && canFetchDeviceWorkloads(device))
}

/** Console/VNC SPA path. Self stays on /vms/:id/vnc. */
export function vncWindowPath(
  device: DeviceApiTarget | null | undefined,
  vmId: string,
): string {
  if (device && !isSelfDevice(device)) {
    return `/devices/${encodeURIComponent(device.hostId)}/vms/${encodeURIComponent(vmId)}/vnc`
  }
  return `/vms/${encodeURIComponent(vmId)}/vnc`
}

export function consoleSocketPath(
  device: DeviceApiTarget | null | undefined,
  vmId: string,
  kind: 'vnc' | 'console',
): string {
  const target = device ?? { hostId: 'self', role: 'self' }
  return kind === 'vnc' ? deviceVmVncPath(target, vmId) : deviceVmConsolePath(target, vmId)
}

export function wsTicketPath(device: DeviceApiTarget | null | undefined): string {
  if (!device) return '/auth/ws-ticket'
  return deviceWsTicketPath(device)
}

/** Device ticket, plus a Home-minted `session=` ticket for member tunnels. */
export function consoleSocketQuery(ticket: string, session?: string | null): string {
  const params = new URLSearchParams({ ticket })
  if (session) params.set('session', session)
  return params.toString()
}
