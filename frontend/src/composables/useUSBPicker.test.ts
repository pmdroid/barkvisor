import { afterEach, beforeEach, describe, expect, mock, test } from 'bun:test'
import { computed, ref } from 'vue'
import api from '../api/client'
import type { HostUSBDevice } from '../api/types'
import { usbCanPersist, usbDeviceKey, usbNoSerialCopy, useUSBPicker } from './useUSBPicker'

const originalGet = api.get

function hostUSB(partial: Partial<HostUSBDevice> & Pick<HostUSBDevice, 'id' | 'vendorId' | 'productId'>): HostUSBDevice {
  return {
    name: partial.name ?? partial.id,
    manufacturer: null,
    serialNumber: null,
    claimedByVMId: null,
    claimedByVMName: null,
    ...partial,
  }
}

describe('useUSBPicker (PAS-240)', () => {
  beforeEach(() => {
    api.get = mock(() => Promise.resolve({ data: [] })) as typeof api.get
  })

  afterEach(() => {
    api.get = originalGet
  })

  test('usbDeviceKey prefers id, then deviceId, then vendor:product[:serial]', () => {
    expect(usbDeviceKey({ id: 'stable', vendorId: '1', productId: '2' })).toBe('stable')
    expect(usbDeviceKey({ vendorId: '046d', productId: 'c52b', deviceId: 'dev-1' })).toBe('dev-1')
    expect(usbDeviceKey({ vendorId: '046d', productId: 'c52b', serialNumber: 'sn' })).toBe('046d:c52b:sn')
    expect(usbDeviceKey({ vendorId: '046d', productId: 'c52b' })).toBe('046d:c52b')
  })

  test('usbCanPersist requires a serial and skips claimed or excluded rows', () => {
    expect(usbCanPersist({
      serialNumber: 'ZX9',
      idUnstable: false,
    })).toBe(true)
    expect(usbCanPersist({
      serialNumber: null,
      idUnstable: true,
    })).toBe(false)
    expect(usbCanPersist({
      serialNumber: 'ZX9',
      claimedByVMId: 'vm-1',
    })).toBe(false)
    expect(usbCanPersist({
      serialNumber: 'ZX9',
      attachable: false,
    })).toBe(false)
    expect(usbNoSerialCopy).toBe('No serial, cannot persist.')
  })

  test('toggle adds and removes an attachable Device USB; claimed rows stay out', () => {
    const picker = useUSBPicker({
      selectedHostId: ref('desk'),
      selectedDevice: computed(() => ({ hostId: 'desk', role: 'self' })),
    })
    const mouse = hostUSB({
      id: '0x046d:0xc52b:SN',
      vendorId: '046d',
      productId: 'c52b',
      name: 'Mouse',
      productName: 'MX',
      serialNumber: 'SN',
    })
    const claimed = hostUSB({
      id: 'claimed-1',
      vendorId: '0781',
      productId: '5581',
      name: 'Stick',
      serialNumber: 'DISK',
      claimedByVMId: 'vm-1',
      claimedByVMName: 'other',
    })
    const blocked = hostUSB({
      id: 'hub-1',
      vendorId: '1d6b',
      productId: '0003',
      name: 'Hub',
      attachable: false,
    })
    const noSerial = hostUSB({
      id: 'bus:001.002',
      vendorId: '1234',
      productId: '5678',
      name: 'Stick',
      idUnstable: true,
    })

    picker.toggleUSBDevice(claimed)
    picker.toggleUSBDevice(blocked)
    picker.toggleUSBDevice(noSerial)
    expect(picker.selectedUSBDevices.value).toEqual([])

    picker.toggleUSBDevice(mouse)
    expect(picker.isUSBSelected(mouse)).toBe(true)
    expect(picker.selectedUSBDevices.value).toEqual([{
      vendorId: '046d',
      productId: 'c52b',
      label: 'MX',
      serialNumber: 'SN',
      deviceId: '0x046d:0xc52b:SN',
    }])

    picker.toggleUSBDevice(mouse)
    expect(picker.isUSBSelected(mouse)).toBe(false)
    expect(picker.selectedUSBDevices.value).toEqual([])

    picker.toggleUSBDevice(mouse)
    picker.removeUSBDevice(picker.selectedUSBDevices.value[0]!)
    expect(picker.selectedUSBDevices.value).toEqual([])
  })

  test('fetchUSBDevices lists the picked Device and clears when that Device is gone', async () => {
    const selectedHostId = ref('studio')
    const selectedDevice = computed(() => (
      selectedHostId.value === 'studio'
        ? { hostId: 'studio', role: 'member' as const }
        : null
    ))
    const get = mock((url: string) => {
      if (url === '/home/devices/studio/v1/system/usb-devices') {
        return Promise.resolve({
          data: [hostUSB({ id: 'kbd', vendorId: '04d9', productId: 'a01c', name: 'Keyboard' })],
        })
      }
      throw new Error(`unexpected GET ${url}`)
    })
    api.get = get as typeof api.get

    const picker = useUSBPicker({ selectedHostId, selectedDevice })
    await picker.fetchUSBDevices()
    expect(picker.hostUSBDevices.value.map((d) => d.id)).toEqual(['kbd'])

    selectedHostId.value = 'missing'
    await picker.fetchUSBDevices()
    expect(picker.hostUSBDevices.value).toEqual([])
  })
})
