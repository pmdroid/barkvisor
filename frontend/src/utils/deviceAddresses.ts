import type { DeviceReachabilityAddresses } from '../api/types'

export function hasReachabilityAddresses(
  addresses?: DeviceReachabilityAddresses | null,
): addresses is DeviceReachabilityAddresses {
  if (!addresses) return false
  return addresses.lan.length > 0 || addresses.tailnet.length > 0
}
