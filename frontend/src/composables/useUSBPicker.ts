import { ref, type ComputedRef, type Ref } from 'vue'
import api from '../api/client'
import type { HostUSBDevice, USBPassthroughDevice } from '../api/types'
import { devicePath, type DeviceApiTarget } from '../utils/homeDeviceApi'

export const usbNoSerialCopy = 'No serial, cannot persist.'

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

export function usbCanPersist(dev: {
  serialNumber?: string | null
  idUnstable?: boolean
  attachable?: boolean
  claimedByVMId?: string | null
}) {
  if (dev.attachable === false || dev.claimedByVMId) return false
  if (dev.idUnstable && !dev.serialNumber) return false
  return Boolean(dev.serialNumber)
}

export function useUSBPicker(opts: {
  selectedHostId: Ref<string>
  selectedDevice: ComputedRef<DeviceApiTarget | null | undefined>
}) {
  const hostUSBDevices = ref<HostUSBDevice[]>([])
  const selectedUSBDevices = ref<USBPassthroughDevice[]>([])
  const showUSBPicker = ref(false)

  async function fetchUSBDevices() {
    try {
      const target = opts.selectedDevice.value
      if (opts.selectedHostId.value && !target) {
        hostUSBDevices.value = []
        return
      }
      const path = target ? devicePath(target, '/system/usb-devices') : '/system/usb-devices'
      const { data } = await api.get(path)
      hostUSBDevices.value = data
    } catch {
      hostUSBDevices.value = []
    }
  }

  function toggleUSBDevice(dev: HostUSBDevice) {
    if (!usbCanPersist(dev)) return
    const key = usbDeviceKey(dev)
    const idx = selectedUSBDevices.value.findIndex((d) => usbDeviceKey(d) === key)
    if (idx >= 0) {
      selectedUSBDevices.value.splice(idx, 1)
    } else {
      selectedUSBDevices.value.push({
        vendorId: dev.vendorId,
        productId: dev.productId,
        label: dev.productName || dev.name,
        serialNumber: dev.serialNumber,
        deviceId: usbDeviceKey(dev),
      })
    }
  }

  function isUSBSelected(dev: HostUSBDevice): boolean {
    const key = usbDeviceKey(dev)
    return selectedUSBDevices.value.some((d) => usbDeviceKey(d) === key)
  }

  function removeUSBDevice(dev: USBPassthroughDevice) {
    const key = usbDeviceKey(dev)
    selectedUSBDevices.value = selectedUSBDevices.value.filter((d) => usbDeviceKey(d) !== key)
  }

  function clearUSBSelection() {
    selectedUSBDevices.value = []
  }

  return {
    hostUSBDevices,
    selectedUSBDevices,
    showUSBPicker,
    fetchUSBDevices,
    toggleUSBDevice,
    isUSBSelected,
    removeUSBDevice,
    clearUSBSelection,
    usbDeviceKey,
    usbCanPersist,
    usbNoSerialCopy,
  }
}
