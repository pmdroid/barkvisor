/**
 * User-facing names (PAS-97 Device, PAS-82 Home).
 * Inventory JSON and OS-level fields stay `host*`.
 * Do not ship `/api/home/*` from these labels.
 */
export const HOME_LABEL = 'Home'
export const HOME_OF_ONE = 'Home of one'
export const DEVICE_LABEL = 'Device'
export const DEVICE_CPU_LABEL = 'Device CPU'
export const DEVICE_MEMORY_LABEL = 'Device Memory'
export const THIS_DEVICE = 'this device'
export const NETWORKS_NAV_LABEL = 'Networks'

/** Product-copy words that must not appear in Vue templates. */
export const FORBIDDEN_PRODUCT_TERMS = [
  'node',
  'nodes',
  'cluster',
  'clusters',
  'datacenter',
  'datacenters',
  'quorum',
] as const
