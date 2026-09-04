export const usbNoSerialCopy = 'No serial. Persist by port path; replug may change it.'
export const usbSessionOnlyCopy = 'Session only — no serial or port path.'

export function usbDeviceKey(dev: {
  deviceId?: string | null
  vendorId: string
  productId: string
  serialNumber?: string | null
  id?: string
}) {
  if ('id' in dev && dev.id) return dev.id
  return dev.deviceId
    || (dev.serialNumber ? `${dev.vendorId}:${dev.productId}:${dev.serialNumber}` : `${dev.vendorId}:${dev.productId}`)
}

export function usbHasPortPath(dev: {
  id?: string | null
  deviceId?: string | null
  bus?: number | null
  address?: number | null
}) {
  const id = dev.id || dev.deviceId
  if (typeof id === 'string' && id.startsWith('bus:')) return true
  return dev.bus != null && dev.address != null
}

export function usbCanPersist(dev: {
  serialNumber?: string | null
  idUnstable?: boolean
  attachable?: boolean
  claimedByVMId?: string | null
  id?: string | null
  deviceId?: string | null
  bus?: number | null
  address?: number | null
}) {
  if (dev.attachable === false || dev.claimedByVMId) return false
  if (dev.serialNumber) return true
  return usbHasPortPath(dev)
}

export function usbPersistHint(dev: {
  serialNumber?: string | null
  id?: string | null
  deviceId?: string | null
  bus?: number | null
  address?: number | null
}) {
  if (dev.serialNumber) return null
  if (usbHasPortPath(dev)) return usbNoSerialCopy
  return usbSessionOnlyCopy
}
